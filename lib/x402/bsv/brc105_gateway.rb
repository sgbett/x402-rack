# frozen_string_literal: true

require "securerandom"
require "json"
require "base64"
require "bsv-sdk"

# NO PAY -> NO CONTENT: this gateway serves content if and only if the
# vendor has verified that the payment transaction was accepted by ARC.
# The invariant is enforced by +#settle_payment!+ (below), which runs
# after payment output verification but BEFORE +consume_prefix!+ and
# +internalize_action+ — the ordering matters for retry semantics.
#
# Settlement is BEEF-type-aware:
# - Full BEEF (+subject_txid+ nil): the client has NOT broadcast — the
#   vendor broadcasts via +arc.broadcast+.
# - Atomic BEEF (+subject_txid+ set): the client signals it already
#   broadcast — the vendor verifies via +arc.status+.
#
# See README "What x402-rack guarantees".

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
      PROTOCOL = "wallet payment"
      COMPRESSED_PUBKEY_HEX = /\A0[23][0-9a-f]{64}\z/
      MAX_DERIVATION_BYTES = 64
      PRINTABLE_ASCII = /\A[\x20-\x7E]+\z/

      # @param key_deriver [BSV::Wallet::KeyDeriver] provides identity key + BRC-42 derivation
      # @param prefix_store [#store!, #valid?, #consume!] replay protection for derivation prefixes
      # @param wallet [#internalize_action] BRC-100 wallet for payment internalisation
      # @param arc_client [#broadcast, #status, nil] ARC client used by the
      #   gateway to settle the payment transaction (broadcast Full BEEF,
      #   verify Atomic BEEF). Required at +settle!+ time — a nil
      #   +arc_client+ silently breaks the NO PAY -> NO CONTENT invariant,
      #   so we fail loudly instead. Construction still permits +nil+ for
      #   unit-test ergonomics; production paths always wire ARC via
      #   +Configuration#shared_arc_client+.
      def initialize(key_deriver:, prefix_store:, wallet:, arc_client: nil)
        @key_deriver = key_deriver
        @prefix_store = prefix_store
        @wallet = wallet
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

      # Verify and internalise a BRC-105 payment.
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
        beef, subject_tx = parse_beef_transaction(payment["transaction"])
        log_derivation_inputs(prefix, suffix, counterparty)
        expected_script = derive_payment_script(prefix, suffix, rack_request)
        log_expected_script(expected_script)
        log_tx_outputs(subject_tx, required_sats, expected_script)
        paid_sats, output_index = verify_payment_output!(subject_tx, required_sats, expected_script)
        # Settle BEFORE consume_prefix! so a legitimate retry after a
        # transient settlement failure can still use the prefix. Consuming
        # first would make the subsequent attempt fail the replay check
        # regardless of whether the client fixed their broadcast.
        settle_payment!(beef, subject_tx, route)
        consume_prefix!(prefix)
        internalize_payment!(
          transaction_b64: payment["transaction"],
          output_index: output_index,
          derivation_prefix: prefix,
          derivation_suffix: suffix,
          sender_identity_key: counterparty
        )
        log_settlement_success(subject_tx, paid_sats, required_sats)
        build_settlement_result(subject_tx, paid_sats)
      end

      private

      # Settle the payment via ARC. The vendor — not the client — is the
      # settlement authority: a 2xx from ARC means the network accepted
      # the tx. Structurally valid BEEF proves nothing about whether the
      # client actually broadcast.
      #
      # Settlement is BEEF-type-aware:
      # - Full BEEF (+subject_txid+ nil): client hasn't broadcast →
      #   vendor broadcasts via +arc.broadcast+.
      # - Atomic BEEF (+subject_txid+ set): client signals it already
      #   broadcast → vendor verifies via +arc.status+.
      #
      # NOTE: if ARC hasn't seen the tx yet on the Atomic path
      # (propagation lag from a just-broadcast client), status raises
      # BroadcastError. In practice this hasn't been observed as an
      # issue. If it becomes one, add a bounded retry here — but
      # observe first, don't pre-build.
      #
      # A nil +@arc_client+ silently breaks the NO PAY -> NO CONTENT
      # invariant, so we raise a configuration error instead of quietly
      # skipping. Production paths always wire ARC via
      # +Configuration#shared_arc_client+.
      #
      # Error mapping mirrors BRC-121:
      # - +BroadcastError+ with +status_code >= 500+   → 503 (ARC outage)
      # - +BroadcastError+ otherwise                    → 402 (client's tx rejected)
      # - Network errors (+SocketError+, +Timeout+, +Errno::*+) → 503
      def settle_payment!(beef, subject_tx, route)
        unless @arc_client
          raise VerificationError.new(
            "gateway misconfigured: arc_client is required for payment settlement", status: 500
          )
        end

        if beef.subject_txid
          # Atomic BEEF: client signals they already broadcast → verify via GET.
          @arc_client.status(subject_tx.txid_hex)
        else
          # Full BEEF: client wants us to broadcast → POST.
          @arc_client.broadcast(subject_tx, wait_for: route.arc_wait_for)
        end
      rescue ::BSV::Network::BroadcastError => e
        txid = subject_tx.txid_hex
        beef_type = beef.subject_txid ? "atomic" : "full"
        if e.status_code.is_a?(Integer) && e.status_code >= 500
          logger.warn "[brc105] ARC outage: txid=#{txid} beef=#{beef_type} " \
                      "status=#{e.status_code} message=#{e.message}"
          raise VerificationError.new("payment verification temporarily unavailable", status: 503)
        end

        logger.info "[brc105] ARC rejected: txid=#{txid} beef=#{beef_type} " \
                    "status=#{e.status_code.inspect} message=#{e.message}"
        raise VerificationError.new("payment not accepted: #{e.message}", status: 402)
      rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH => e
        logger.warn "[brc105] ARC network failure: txid=#{subject_tx.txid_hex} #{e.class}: #{e.message}"
        raise VerificationError.new("payment verification temporarily unavailable", status: 503)
      end

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

        # Atomic BEEF embeds a subject_txid; Full BEEF does not — derive
        # it from the last raw transaction in the bundle (dependency order
        # puts the subject last).
        txid = beef.subject_txid || beef.transactions.reverse_each.find(&:transaction)&.txid
        raise VerificationError.new("no subject transaction in BEEF bundle", status: 400) unless txid

        # find_atomic_transaction wires ancestry (source_transaction on each
        # input). Required so arc.broadcast(subject_tx) can emit EF —
        # otherwise we fall back to raw hex and ARC rejects broadcasts whose
        # parents are unconfirmed and only present in the BEEF. See #177.
        subject_tx = beef.find_atomic_transaction(txid)
        raise VerificationError.new("no subject transaction in BEEF bundle", status: 400) unless subject_tx

        [beef, subject_tx]
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
        transaction.outputs.each_with_index do |output, i|
          next unless output.locking_script == expected_script && output.satoshis >= required_sats

          return [output.satoshis, i]
        end

        raise VerificationError.new(
          "no output pays >= #{required_sats} sats to derived address", status: 402
        )
      end

      def internalize_payment!(transaction_b64:, output_index:, derivation_prefix:, derivation_suffix:,
                               sender_identity_key:)
        tx_bytes = Base64.strict_decode64(transaction_b64).unpack("C*")
        @wallet.internalize_action({
                                     tx: tx_bytes,
                                     outputs: [{
                                       output_index: output_index,
                                       protocol: PROTOCOL,
                                       payment_remittance: {
                                         derivation_prefix: derivation_prefix,
                                         derivation_suffix: derivation_suffix,
                                         sender_identity_key: sender_identity_key
                                       }
                                     }],
                                     description: "BRC-105 payment"
                                   })
      rescue VerificationError
        raise
      rescue StandardError => e
        logger.error "[brc105] internalize_action failed: sender=#{sender_identity_key[0..15]}... " \
                     "prefix=#{derivation_prefix} vout=#{output_index} #{e.class}: #{e.message}"
        raise VerificationError.new("payment internalisation failed", status: 402)
      end

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
          "network" => X402.configuration.network
        }
        SettlementResult.new(
          receipt_headers: {
            "x-bsv-payment-satoshis-paid" => paid_sats.to_s,
            "x-bsv-payment-result" => Base64.strict_encode64(JSON.generate(receipt))
          },
          txid: transaction.txid_hex,
          network: X402.configuration.network
        )
      end
    end
  end
end
