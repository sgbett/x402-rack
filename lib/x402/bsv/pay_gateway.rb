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
    class PayGateway < Gateway # rubocop:disable Metrics/ClassLength
      DEFAULT_ARC_WAIT_FOR = "SEEN_ON_NETWORK"
      DEFAULT_ARC_TIMEOUT = 5
      DEFAULT_MAX_TIMEOUT_SECONDS = 60
      NETWORK = "bsv:mainnet"
      ASSET = "BSV"
      SCHEME = "exact"

      attr_reader :arc_client, :arc_wait_for, :arc_timeout, :binding_mode

      # @param arc_client [#broadcast] ARC client for broadcasting
      # @param arc_wait_for [String] ARC X-WaitFor header value
      # @param arc_timeout [Integer] seconds before ARC timeout
      # @param binding_mode [Symbol] :strict or :permissive for OP_RETURN binding
      # @param payee_locking_script_hex [String, nil] payee script (falls back to config)
      def initialize(arc_client:, arc_wait_for: DEFAULT_ARC_WAIT_FOR,
                     arc_timeout: DEFAULT_ARC_TIMEOUT, binding_mode: :permissive,
                     payee_locking_script_hex: nil)
        super(payee_locking_script_hex: payee_locking_script_hex)
        @arc_client = arc_client
        @arc_wait_for = arc_wait_for
        @arc_timeout = arc_timeout
        @binding_mode = binding_mode
      end

      def challenge_headers(rack_request, route)
        challenge = build_challenge(rack_request, route)
        { "Payment-Required" => Base64.strict_encode64(JSON.generate(challenge)) }
      end

      def proof_header_names
        ["Payment-Signature"]
      end

      def settle!(_header_name, proof_payload, rack_request, route)
        payload = decode_payment_payload(proof_payload)
        verify_accepted!(payload, route)
        transaction = decode_transaction(payload)
        verify_payment_output!(transaction, route)
        verify_binding!(transaction, rack_request)
        broadcast!(transaction)
        build_settlement_result(transaction)
      end

      private

      def build_challenge(rack_request, route)
        template = build_template(rack_request, route)
        payee_hex = @payee_locking_script_hex || X402.configuration.payee_locking_script_hex

        {
          "x402Version" => 2,
          "resource" => { "url" => rack_request.path_info },
          "accepts" => [build_accept_entry(payee_hex, route, template)]
        }
      end

      def build_accept_entry(payee_hex, route, template)
        {
          "scheme" => SCHEME,
          "network" => NETWORK,
          "amount" => route.amount_sats.to_s,
          "asset" => ASSET,
          "payTo" => payee_hex,
          "maxTimeoutSeconds" => DEFAULT_MAX_TIMEOUT_SECONDS,
          "extra" => { "partialTx" => Base64.strict_encode64(template.to_binary) }
        }
      end

      def decode_payment_payload(proof_payload)
        json = Base64.strict_decode64(proof_payload)
        JSON.parse(json)
      rescue ArgumentError, JSON::ParserError => e
        raise VerificationError.new("invalid payment payload: #{e.message}", status: 400)
      end

      def verify_accepted!(payload, route)
        accepted = payload["accepted"]
        raise VerificationError.new("missing accepted field", status: 400) unless accepted
        if accepted["network"] != NETWORK
          raise VerificationError.new("network mismatch: expected #{NETWORK}", status: 400)
        end

        amount = accepted["amount"].to_i
        return unless amount < route.amount_sats

        raise VerificationError.new("insufficient amount: #{amount} < #{route.amount_sats}", status: 402)
      end

      def decode_transaction(payload)
        rawtx_hex = payload.dig("payload", "rawtx")
        raise VerificationError.new("missing payload.rawtx", status: 400) unless rawtx_hex

        raw = [rawtx_hex].pack("H*")
        ::BSV::Transaction::Transaction.from_binary(raw)
      rescue VerificationError
        raise
      rescue StandardError => e
        raise VerificationError.new("failed to decode transaction: #{e.message}", status: 400)
      end

      def verify_payment_output!(transaction, route)
        payee_script = resolve_payee_script
        found = transaction.outputs.any? do |output|
          output.locking_script == payee_script && output.satoshis >= route.amount_sats
        end
        return if found

        raise VerificationError.new("no output pays >= #{route.amount_sats} sats to payee", status: 402)
      end

      def verify_binding!(transaction, rack_request)
        expected_hex = "006a20#{request_binding_hash(rack_request).unpack1("H*")}"
        found = transaction.outputs.any? do |output|
          output.locking_script.op_return? && output.locking_script.to_hex == expected_hex
        end

        return if found
        return if binding_mode == :permissive

        raise VerificationError.new("OP_RETURN request binding mismatch", status: 400)
      end

      def broadcast!(transaction)
        arc_client.broadcast(transaction)
      rescue StandardError => e
        raise VerificationError.new("ARC broadcast failed: #{e.message}", status: 502)
      end

      def build_settlement_result(transaction)
        receipt = { "success" => true, "transaction" => transaction.txid_hex, "network" => NETWORK }
        SettlementResult.new(
          receipt_headers: { "Payment-Response" => Base64.strict_encode64(JSON.generate(receipt)) },
          txid: transaction.txid_hex,
          network: NETWORK
        )
      end
    end
  end
end
