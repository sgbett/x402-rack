# frozen_string_literal: true

require "json"
require "base64"

module X402
  module BSV
    # BSV-native payment gateway using Coinbase v2 headers.
    #
    # Challenge: Payment-Required (v2 PaymentRequired JSON with extra.partialTx)
    # Proof:     Payment-Signature (v2 PaymentPayload JSON with rawtx + txid)
    # Receipt:   Payment-Response (settlement result JSON)
    #
    # Server broadcasts via ARC. No nonces needed — ARC is the replay gate.
    class PayGateway < Gateway
      DEFAULT_ARC_WAIT_FOR = "SEEN_ON_NETWORK"
      DEFAULT_ARC_TIMEOUT = 5
      DEFAULT_MAX_TIMEOUT_SECONDS = 60
      ASSET = "BSV"
      SCHEME = "exact"

      attr_reader :arc_client, :arc_wait_for, :arc_timeout, :binding_mode, :settlement_worker

      # @param arc_client [#broadcast] ARC client for broadcasting
      # @param arc_wait_for [String] ARC X-WaitFor header value
      # @param arc_timeout [Integer] seconds before ARC timeout
      # @param binding_mode [Symbol] :strict or :permissive for OP_RETURN binding
      # @param payee_locking_script_hex [String, nil] payee script (falls back to config)
      # @param settlement_worker [#enqueue, nil] async settlement worker
      # @param txid_store [#seen?, #record!, nil] optional txid deduplication store.
      #   When provided, rejects proofs whose txid has already been settled.
      def initialize(arc_client:, arc_wait_for: DEFAULT_ARC_WAIT_FOR,
                     arc_timeout: DEFAULT_ARC_TIMEOUT, binding_mode: :strict,
                     payee_locking_script_hex: nil, wallet: nil, challenge_secret: nil,
                     settlement_worker: nil, txid_store: nil)
        super(payee_locking_script_hex: payee_locking_script_hex, wallet: wallet,
              challenge_secret: challenge_secret)
        @arc_client = arc_client
        @arc_wait_for = arc_wait_for
        @arc_timeout = arc_timeout
        @binding_mode = binding_mode
        @settlement_worker = settlement_worker
        @txid_store = txid_store
      end

      # Build a 402 challenge with Coinbase v2 +Payment-Required+ header.
      #
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [Hash] challenge headers
      def challenge_headers(rack_request, route)
        challenge = build_challenge(rack_request, route)
        { "Payment-Required" => Base64.strict_encode64(JSON.generate(challenge)) }
      end

      # @return [Array<String>] proof header names this gateway responds to
      def proof_header_names
        ["Payment-Signature"]
      end

      # Verify and broadcast a Coinbase v2 payment.
      #
      # @param _header_name [String] which proof header matched
      # @param proof_payload [String] base64-encoded payment payload
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [SettlementResult]
      # @raise [VerificationError] on invalid payment, insufficient amount, or broadcast failure
      def settle!(_header_name, proof_payload, rack_request, route)
        required_sats = route.resolve_amount_sats
        payload = decode_payment_payload(proof_payload)
        verify_accepted!(payload, required_sats)
        accepted_payee = payload.dig("accepted", "payTo")
        pay_to_sig = payload.dig("accepted", "extra", "payToSig")
        prefix = payload.dig("accepted", "extra", "derivationPrefix")
        suffix = payload.dig("accepted", "extra", "derivationSuffix")
        verify_pay_to_signature!(accepted_payee, pay_to_sig, prefix, suffix)
        transaction = decode_transaction(payload)
        check_txid_unique!(transaction)
        verify_payment_output!(transaction, required_sats, accepted_payee)
        verify_binding!(transaction, rack_request)
        settle_transaction!(transaction, route)
        relay_to_wallet(transaction, prefix, suffix)
        build_settlement_result(transaction)
      end

      private

      def build_challenge(rack_request, route)
        required_sats = route.resolve_amount_sats
        template, payee_hex, prefix, suffix = build_template(rack_request, required_sats)

        # PayGateway includes OP_RETURN in the template (no fee delegation index issues)
        binding_hash = request_binding_hash(rack_request)
        template.add_output(::BSV::Transaction::TransactionOutput.new(
                              satoshis: 0,
                              locking_script: build_op_return_script(binding_hash)
                            ))

        {
          "x402Version" => 2,
          "resource" => { "url" => rack_request.path_info },
          "accepts" => [build_accept_entry(payee_hex, required_sats, template, prefix, suffix)]
        }
      end

      def build_accept_entry(payee_hex, required_sats, template, prefix, suffix)
        extra = {
          "partialTx" => Base64.strict_encode64(template.to_binary),
          "payToSig" => sign_pay_to(payee_hex, prefix, suffix)
        }
        if prefix
          extra["derivationPrefix"] = prefix
          extra["derivationSuffix"] = suffix
        end

        {
          "scheme" => SCHEME,
          "network" => X402.configuration.network,
          "amount" => required_sats.to_s,
          "asset" => ASSET,
          "payTo" => payee_hex,
          "maxTimeoutSeconds" => DEFAULT_MAX_TIMEOUT_SECONDS,
          "extra" => extra
        }
      end

      def decode_payment_payload(proof_payload)
        json = Base64.strict_decode64(proof_payload)
        JSON.parse(json)
      rescue ArgumentError, JSON::ParserError
        raise VerificationError.new("invalid payment payload", status: 400)
      end

      def verify_accepted!(payload, required_sats)
        accepted = payload["accepted"]
        raise VerificationError.new("missing accepted field", status: 400) unless accepted
        if accepted["network"] != X402.configuration.network
          raise VerificationError.new("network mismatch: expected #{X402.configuration.network}", status: 400)
        end

        raw_amount = accepted["amount"]
        amount = raw_amount.is_a?(Integer) ? raw_amount : Integer(raw_amount, 10)
        return unless amount < required_sats

        raise VerificationError.new("insufficient amount: #{amount} < #{required_sats}", status: 402)
      rescue ArgumentError, TypeError
        raise VerificationError.new("invalid amount field", status: 400)
      end

      def decode_transaction(payload)
        rawtx_hex = payload.dig("payload", "rawtx")
        raise VerificationError.new("missing payload.rawtx", status: 400) unless rawtx_hex

        raw = [rawtx_hex].pack("H*")
        ::BSV::Transaction::Transaction.from_binary(raw)
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError.new("failed to decode transaction", status: 400)
      end

      def verify_payment_output!(transaction, required_sats, payee_hex)
        payee_script = payee_script_from_hex(payee_hex)
        found = transaction.outputs.any? do |output|
          output.locking_script == payee_script && output.satoshis >= required_sats
        end
        return if found

        raise VerificationError.new("no output pays >= #{required_sats} sats to payee", status: 402)
      end

      def check_txid_unique!(transaction)
        return unless @txid_store
        return if @txid_store.record_if_unseen!(transaction.txid_hex)

        raise VerificationError.new("transaction already settled", status: 400)
      end

      def verify_binding!(transaction, rack_request)
        expected_script = build_op_return_script(request_binding_hash(rack_request))
        found = transaction.outputs.any? do |output|
          output.locking_script.op_return? && output.locking_script.to_hex == expected_script.to_hex
        end

        return if found
        return if binding_mode == :permissive

        raise VerificationError.new("OP_RETURN request binding mismatch", status: 400)
      end

      # Determine the effective wait_for strategy and either broadcast
      # synchronously or enqueue for async settlement.
      def settle_transaction!(transaction, route)
        effective = (route.arc_wait_for || arc_wait_for).to_s

        if effective == "async"
          unless settlement_worker
            raise ConfigurationError,
                  "route arc_wait_for is :async but no settlement_worker configured"
          end
          settlement_worker.enqueue(transaction.to_binary)
        else
          broadcast!(transaction, wait_for: effective)
        end
      end

      def broadcast!(transaction, wait_for: arc_wait_for)
        arc_client.broadcast(transaction, wait_for: wait_for)
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError.new("ARC broadcast failed", status: 502)
      end

      # Relay the settled transaction to the operator's wallet for tracking.
      # This is a notification, not a gate — if it fails, the payment has
      # already landed on-chain via ARC and settlement proceeds normally.
      def relay_to_wallet(transaction, prefix, suffix)
        return unless @wallet
        return unless prefix

        internalize_payment!(transaction, prefix, suffix)
      rescue StandardError => e
        logger.warn "[pay-gateway] wallet internalisation failed (non-fatal): #{e.class}: #{e.message}"
      end

      # Output 0 is always the payment output — built by build_template.
      # The sender_identity_key is the wallet's own identity key because
      # derive_unique_payee_hex uses forSelf derivation (no counterparty).
      def internalize_payment!(transaction, prefix, suffix)
        identity = @wallet.get_public_key({ identity_key: true })
        sender_key = identity[:public_key] || identity["public_key"]
        tx_bytes = transaction.to_binary.unpack("C*")
        @wallet.internalize_action(
          tx: tx_bytes,
          outputs: [{
            output_index: 0,
            protocol: "wallet payment",
            payment_remittance: {
              derivation_prefix: prefix,
              derivation_suffix: suffix,
              sender_identity_key: sender_key
            }
          }],
          description: "PayGateway payment"
        )
      end

      def build_settlement_result(transaction)
        receipt = { "success" => true, "transaction" => transaction.txid_hex, "network" => X402.configuration.network }
        SettlementResult.new(
          receipt_headers: { "Payment-Response" => Base64.strict_encode64(JSON.generate(receipt)) },
          txid: transaction.txid_hex,
          network: X402.configuration.network
        )
      end

      def logger
        X402.configuration.logger
      end
    end
  end
end
