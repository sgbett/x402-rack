# frozen_string_literal: true

require "securerandom"
require "json"
require "base64"
require "bsv-sdk"

module X402
  module BSV
    # BRC-105 gateway for BSV settlement-gated HTTP.
    #
    # Unlike PayGateway/ProofGateway, this does NOT inherit from Gateway.
    # BRC-105 uses a fundamentally different pattern: no partial tx template,
    # no OP_RETURN binding, no payTo HMAC. Key derivation (BRC-42/43) via
    # KeyDeriver replaces the template-based approach.
    #
    # Implements the three-method gateway interface required by Middleware:
    #   challenge_headers(rack_request, route) → Hash
    #   proof_header_names → Array<String>
    #   settle!(header_name, proof_payload, rack_request, route) → SettlementResult
    class BRC105Gateway
      PROTOCOL_ID = [2, "3241645161d8"].freeze
      PROOF_HEADER = "x-bsv-payment"
      NETWORK = "bsv:mainnet"
      COMPRESSED_PUBKEY_HEX = /\A0[23][0-9a-f]{64}\z/
      MAX_DERIVATION_BYTES = 64
      PRINTABLE_ASCII = /\A[\x20-\x7E]+\z/

      # @param key_deriver [BSV::Wallet::KeyDeriver] provides identity key + BRC-42 derivation
      # @param prefix_store [#store!, #valid?, #consume!] replay protection for derivation prefixes
      # @param arc_client [#broadcast] ARC client for broadcasting transactions
      def initialize(key_deriver:, prefix_store:, arc_client:)
        @key_deriver = key_deriver
        @prefix_store = prefix_store
        @arc_client = arc_client
      end

      # Issue a 402 challenge with BRC-105 headers.
      #
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [Hash] challenge headers (x-bsv-* namespace)
      def challenge_headers(rack_request, route)
        prefix = SecureRandom.hex(16)
        begin
          @prefix_store.store!(prefix)
        rescue PrefixStore::StoreFullError
          raise VerificationError.new("server at capacity — try again later", status: 503)
        end

        headers = {
          "x-bsv-payment-version" => "1.0",
          "x-bsv-payment-satoshis-required" => route.resolve_amount_sats.to_s,
          "x-bsv-payment-derivation-prefix" => prefix
        }

        # The 402 challenge is issued before the client authenticates (no
        # x-bsv-auth-identity-key yet). Include the server's identity key so
        # the client knows who to derive the payment address for. When BRC-103
        # mutual auth is already established, the client already has this key.
        headers["x-bsv-payment-identity-key"] = @key_deriver.identity_key unless validated_brc103_key(rack_request)

        headers
      end

      # Header names that carry the proof/payment from the client.
      #
      # @return [Array<String>]
      def proof_header_names
        [PROOF_HEADER]
      end

      # Verify and broadcast a BRC-105 payment.
      #
      # @param _header_name [String] which proof header matched
      # @param proof_payload [String] raw header value
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [SettlementResult]
      def settle!(_header_name, proof_payload, rack_request, route)
        # §7.1: fail fast if unauthenticated — before parsing untrusted payload
        counterparty = resolve_counterparty(rack_request)
        required_sats = route.resolve_amount_sats
        payment = parse_payment(proof_payload)
        prefix = payment["derivationPrefix"]
        suffix = payment["derivationSuffix"]
        validate_prefix_and_suffix!(prefix, suffix)
        subject_tx = parse_beef_transaction(payment["transaction"])
        log_derivation_inputs(prefix, suffix, counterparty)
        expected_script = derive_payment_script(prefix, suffix, rack_request)
        log_expected_script(expected_script)
        log_tx_outputs(subject_tx, required_sats, expected_script)
        paid_sats = verify_payment_output!(subject_tx, required_sats, expected_script)
        consume_prefix!(prefix)
        broadcast!(subject_tx)
        log_settlement_success(subject_tx, paid_sats, required_sats)
        build_settlement_result(subject_tx, paid_sats)
      end

      private

      def parse_payment(proof_payload)
        JSON.parse(proof_payload)
      rescue JSON::ParserError
        raise VerificationError.new("invalid payment JSON", status: 400)
      end

      def validate_prefix_and_suffix!(prefix, suffix)
        validate_hex!("derivationPrefix", prefix)
        validate_suffix!("derivationSuffix", suffix)
      end

      # Prefix is server-generated hex (SecureRandom.hex).
      def validate_hex!(name, value)
        raise VerificationError.new("missing #{name}", status: 400) if value.nil?
        unless value.is_a?(String) && !value.empty? &&
               value.bytesize <= MAX_DERIVATION_BYTES && value.match?(/\A[0-9a-f]+\z/)
          raise VerificationError.new("invalid #{name} format", status: 400)
        end
      end

      # Suffix is client-generated — the BRC-105 spec does not constrain the
      # format. Reference implementations (BRC-121, bsv-x402) use base64.
      # We accept any printable ASCII string within the size limit.
      def validate_suffix!(name, value)
        raise VerificationError.new("missing #{name}", status: 400) if value.nil?
        unless value.is_a?(String) && !value.empty? &&
               value.bytesize <= MAX_DERIVATION_BYTES && value.match?(PRINTABLE_ASCII)
          raise VerificationError.new("invalid #{name} format", status: 400)
        end
      end

      def consume_prefix!(prefix)
        return if @prefix_store.consume!(prefix)

        raise VerificationError.new("replay: derivation prefix already consumed or unknown", status: 400)
      end

      def parse_beef_transaction(transaction_b64)
        raise VerificationError.new("missing transaction field", status: 400) if transaction_b64.nil?

        raw = Base64.strict_decode64(transaction_b64)
        beef = ::BSV::Transaction::Beef.from_binary(raw)
        subject_tx = beef.find_transaction(beef.subject_txid)
        raise VerificationError.new("no subject transaction in BEEF bundle", status: 400) unless subject_tx

        subject_tx
      rescue ArgumentError
        raise VerificationError.new("invalid base64 in transaction", status: 400)
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError.new("failed to parse BEEF transaction", status: 400)
      end

      def derive_payment_script(prefix, suffix, rack_request)
        counterparty = resolve_counterparty(rack_request)
        key_id = "#{prefix} #{suffix}"
        pubkey = @key_deriver.derive_public_key(PROTOCOL_ID, key_id, counterparty, for_self: true)
        h160 = pubkey.hash160.unpack1("H*")
        ::BSV::Script::Script.from_hex("76a914#{h160}88ac")
      end

      # BRC-105 §7.1: "If not authenticated, respond 401 Unauthorized."
      # The client's identity key is required for BRC-42 key derivation.
      def resolve_counterparty(rack_request)
        key = rack_request.env["brc103.identity_key"]
        return key if key.is_a?(String) && key.match?(COMPRESSED_PUBKEY_HEX)

        if key.nil? || (key.is_a?(String) && key.empty?)
          raise VerificationError.new("missing client identity key (x-bsv-auth-identity-key)", status: 401)
        end

        raise VerificationError.new("invalid client identity key (x-bsv-auth-identity-key)", status: 401)
      end

      # Returns the validated BRC-103 identity key from the Rack env, or nil
      # if absent or not a valid compressed public key hex.
      # Used by challenge_headers to check for BRC-103 presence.
      def validated_brc103_key(rack_request)
        key = rack_request.env["brc103.identity_key"]
        key if key.is_a?(String) && key.match?(COMPRESSED_PUBKEY_HEX)
      end

      def verify_payment_output!(transaction, required_sats, expected_script)
        matching = transaction.outputs.find do |output|
          output.locking_script == expected_script && output.satoshis >= required_sats
        end

        unless matching
          raise VerificationError.new(
            "no output pays >= #{required_sats} sats to derived address", status: 402
          )
        end

        matching.satoshis
      end

      def broadcast!(transaction)
        @arc_client.broadcast(transaction)
      rescue StandardError
        raise VerificationError.new("ARC broadcast failed", status: 502)
      end

      # NOTE: x-bsv-payment-satoshis-paid reflects the amount claimed in the
      # BEEF transaction, verified against the derived payment script but set
      # before ARC broadcast confirmation. It is not an on-chain-confirmed
      # value. Downstream consumers requiring confirmed amounts should use
      # the txid to query chain state independently.
      # --- Settlement logging (tagged [brc105]) ---

      def logger
        X402.configuration.logger
      end

      def log_derivation_inputs(prefix, suffix, counterparty)
        logger.info "[brc105] Derivation: prefix=#{prefix} suffix=#{suffix} counterparty=#{counterparty}"
        logger.debug "[brc105] Key ID: #{prefix} #{suffix}"
      end

      def log_expected_script(script)
        logger.info "[brc105] Expected locking script: #{script.to_hex}"
      end

      def log_tx_outputs(transaction, required_sats, expected_script)
        logger.info "[brc105] Verifying #{transaction.outputs.length} output(s) against #{required_sats} sats required"
        transaction.outputs.each_with_index do |output, i|
          script_match = output.locking_script == expected_script
          sats_match = output.satoshis >= required_sats
          logger.info "[brc105]   output[#{i}]: #{output.satoshis} sats, " \
                      "script=#{output.locking_script.to_hex[0..15]}... " \
                      "script_match=#{script_match} sats_match=#{sats_match}"
        end
      end

      def log_settlement_success(transaction, paid_sats, required_sats)
        logger.info "[brc105] Settlement OK: txid=#{transaction.txid_hex} " \
                    "paid=#{paid_sats} required=#{required_sats}"
      end

      def build_settlement_result(transaction, paid_sats)
        receipt = {
          "success" => true,
          "transaction" => transaction.txid_hex,
          "network" => NETWORK
        }
        SettlementResult.new(
          receipt_headers: {
            "x-bsv-payment-satoshis-paid" => paid_sats.to_s,
            "x-bsv-payment-result" => Base64.strict_encode64(JSON.generate(receipt))
          },
          txid: transaction.txid_hex,
          network: NETWORK
        )
      end
    end
  end
end
