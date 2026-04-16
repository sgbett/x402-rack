# frozen_string_literal: true

require "base64"
require "bsv-sdk"
require_relative "network_visibility"
require_relative "txid_store"

# NO PAY -> NO CONTENT: this gateway serves content if and only if the
# payment transaction is visible on the BSV network. The invariant is
# enforced by +#verify_visibility!+ (below), which is called between
# validation and +internalize_action+ so wallet state is never mutated
# for an unbroadcast tx. See README "What x402-rack guarantees" and
# +X402::BSV::NetworkVisibility+ for the shared retry / cache /
# 402-vs-503 classification.

module X402
  module BSV
    # BRC-121 ("Simple 402 Payments") gateway for BSV settlement-gated HTTP.
    #
    # BRC-121 is the BSV Association's simple HTTP payment protocol. The server
    # is stateless: replay protection comes from a 30-second timestamp freshness
    # window (§5 step 2) plus the wallet's handling of duplicate incoming
    # transactions.
    #
    # Unlike BRC-105, BRC-121 does not use server-generated derivation prefixes
    # or a PrefixStore. The client generates the derivation prefix, chooses a
    # timestamp as the suffix, constructs a BRC-29 payment, and submits it all
    # in one round trip with no prior handshake.
    #
    # Spec: https://hub.bsvblockchain.org/brc/payments/0121
    #
    # == Headers
    #
    # Challenge (server → client):
    #   x-bsv-sats     — required satoshi amount
    #   x-bsv-server   — server's identity public key (compressed hex)
    #
    # Proof (client → server):
    #   x-bsv-beef     — base64 BEEF transaction (the proof header)
    #   x-bsv-sender   — client's identity public key (compressed hex)
    #   x-bsv-nonce    — base64 BRC-29 derivation prefix
    #   x-bsv-time     — decimal Unix millisecond timestamp
    #   x-bsv-vout     — decimal output index of the payment
    #
    # == Replay protection
    #
    # BRC-121 §5 step 2: the +x-bsv-time+ header MUST be within 30 seconds of
    # the server's current time. This is the primary defence against capture
    # and delayed replay.
    #
    # BRC-121 §5 step 5 also specifies checking +isMerge+ on the wallet's
    # internalization result. The current Ruby +BSV::Wallet::WalletClient+
    # does not return an +isMerge+ field, so this gateway additionally uses
    # an +X402::BSV::TxidStore+ to reject duplicate txids within the freshness
    # window.
    #
    # Implements the three-method gateway interface required by Middleware:
    #   challenge_headers(rack_request, route) → Hash
    #   proof_header_names → Array<String>
    #   settle!(header_name, proof_payload, rack_request, route) → SettlementResult
    class BRC121Gateway
      PROOF_HEADER = "x-bsv-beef"
      FRESHNESS_WINDOW_MS = 30_000
      COMPRESSED_PUBKEY_HEX = /\A0[23][0-9a-f]{64}\z/
      # BRC-29 derivation prefix is base64. Cap length at 128 chars
      # (~96 bytes decoded) — well above realistic nonce sizes.
      BASE64_NONCE = %r{\A[A-Za-z0-9+/]{1,128}={0,2}\z}
      PROTOCOL = "wallet payment"
      CLIENT_HEADERS = %w[x-bsv-beef x-bsv-sender x-bsv-nonce x-bsv-time x-bsv-vout].freeze

      # @param wallet [#internalize_action, #get_public_key] BRC-100 wallet.
      #   Must respond to +#internalize_action(args)+ (per
      #   bsv-ruby-sdk +BSV::Wallet::WalletClient+) and
      #   +#get_public_key(identity_key: true)+ for the server identity key.
      # @param txid_store [#record_if_unseen!, nil] replay protection for
      #   settled txids. Defaults to +X402::BSV::TxidStore::Memory.new+.
      # @param arc_client [#status, nil] ARC client used to confirm the
      #   payment txid is visible on the BSV network before the wallet
      #   internalises it. When +nil+ (backward compatibility), the
      #   visibility check is skipped entirely.
      # @param network_visibility_cache [NetworkVisibility::Cache, nil]
      #   per-gateway positive-only TTL cache shielding ARC from
      #   duplicate-submission bursts. Defaults to a fresh
      #   +NetworkVisibility::Cache.new+.
      def initialize(wallet:, txid_store: nil, arc_client: nil, network_visibility_cache: nil)
        @wallet = wallet
        @txid_store = txid_store || TxidStore::Memory.new
        @arc_client = arc_client
        @network_visibility_cache = network_visibility_cache || NetworkVisibility::Cache.new
      end

      # Issue a 402 challenge with BRC-121 headers.
      #
      # @param _rack_request [Rack::Request] unused (stateless protocol)
      # @param route [X402::Configuration::Route]
      # @return [Hash] challenge headers (+x-bsv-sats+, +x-bsv-server+)
      def challenge_headers(_rack_request, route)
        {
          "x-bsv-sats" => route.resolve_amount_sats.to_s,
          "x-bsv-server" => server_identity_key
        }
      end

      # Header names that carry the proof/payment from the client.
      #
      # @return [Array<String>]
      def proof_header_names
        [PROOF_HEADER]
      end

      # Verify and internalise a BRC-121 payment.
      #
      # @param _header_name [String] which proof header matched
      # @param _proof_payload [String] the +x-bsv-beef+ header value (read
      #   directly from the rack env alongside the other four client headers)
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [SettlementResult]
      # @raise [VerificationError] on missing/invalid headers, stale timestamp,
      #   insufficient payment, replay, or internalisation failure
      def settle!(_header_name, _proof_payload, rack_request, route)
        required_sats = route.resolve_amount_sats
        headers = extract_client_headers!(rack_request)
        validate_sender_identity_key!(headers["x-bsv-sender"])
        validate_nonce!(headers["x-bsv-nonce"])
        validate_timestamp_freshness!(headers["x-bsv-time"])
        output_index = parse_output_index!(headers["x-bsv-vout"])
        subject_tx = parse_beef_transaction(headers["x-bsv-beef"])

        check_txid_unique!(subject_tx.txid_hex)

        paid_sats = verify_payment_output!(subject_tx, output_index, required_sats)

        verify_visibility!(subject_tx.txid_hex)

        result = internalize_payment!(
          beef_b64: headers["x-bsv-beef"],
          output_index: output_index,
          derivation_prefix: headers["x-bsv-nonce"],
          derivation_suffix: Base64.strict_encode64(headers["x-bsv-time"]),
          sender_identity_key: headers["x-bsv-sender"]
        )

        check_internalization_result!(result)

        log_settlement_success(subject_tx, paid_sats, required_sats)
        build_settlement_result(subject_tx, paid_sats)
      end

      private

      def server_identity_key
        result = @wallet.get_public_key(identity_key: true)
        result.is_a?(Hash) ? (result[:public_key] || result["publicKey"]) : result
      end

      def extract_client_headers!(rack_request)
        headers = CLIENT_HEADERS.each_with_object({}) do |name, acc|
          rack_key = "HTTP_#{name.upcase.tr("-", "_")}"
          acc[name] = rack_request.env[rack_key]
        end

        missing = CLIENT_HEADERS.reject { |h| headers[h].is_a?(String) && !headers[h].empty? }
        unless missing.empty?
          raise VerificationError.new("missing required BRC-121 headers: #{missing.join(", ")}", status: 402)
        end

        headers
      end

      def validate_sender_identity_key!(sender)
        return if sender.is_a?(String) && sender.match?(COMPRESSED_PUBKEY_HEX)

        raise VerificationError.new("invalid x-bsv-sender (expected 33-byte compressed pubkey hex)", status: 400)
      end

      # BRC-121 §1: "Base64-encoded BRC-29 derivation prefix for the payment."
      # Validate format, decodability, and length before passing to the
      # wallet — an unvalidated attacker-controlled string should not reach
      # the cryptographic derivation pipeline.
      def validate_nonce!(nonce)
        # Quick reject: must look like base64 and stay under the length cap.
        unless nonce.match?(BASE64_NONCE)
          raise VerificationError.new("invalid x-bsv-nonce (expected base64 derivation prefix)", status: 400)
        end

        # Strict decode: reject padding errors and non-canonical encodings.
        Base64.strict_decode64(nonce)
      rescue ArgumentError
        raise VerificationError.new("invalid x-bsv-nonce (not decodable as strict base64)", status: 400)
      end

      # §5 step 2: "If the value is not a valid number, or differs from the
      # server's current time by more than 30 seconds, the server MUST reject
      # the request and respond with 402."
      def validate_timestamp_freshness!(time_str)
        unless time_str.match?(/\A\d+\z/)
          raise VerificationError.new("x-bsv-time must be a decimal millisecond timestamp", status: 400)
        end

        time_ms = Integer(time_str, 10)
        now_ms = (Time.now.to_f * 1000).to_i
        return if (now_ms - time_ms).abs <= FRESHNESS_WINDOW_MS

        raise VerificationError.new("x-bsv-time outside 30s freshness window", status: 402)
      end

      def parse_output_index!(vout_str)
        unless vout_str.match?(/\A\d+\z/)
          raise VerificationError.new("x-bsv-vout must be a decimal integer",
                                      status: 400)
        end

        Integer(vout_str, 10)
      end

      def parse_beef_transaction(transaction_b64)
        raw = Base64.strict_decode64(transaction_b64)
        beef = ::BSV::Transaction::Beef.from_binary(raw)
        subject_tx = beef.find_transaction(beef.subject_txid)
        raise VerificationError.new("no subject transaction in BEEF bundle", status: 400) unless subject_tx

        subject_tx
      rescue ArgumentError
        raise VerificationError.new("invalid base64 in x-bsv-beef", status: 400)
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError.new("failed to parse BEEF transaction", status: 400)
      end

      def check_txid_unique!(txid)
        return if @txid_store.record_if_unseen!(txid)

        raise VerificationError.new("replay: transaction already settled", status: 402)
      end

      # Confirm the payment txid is visible on the BSV network before we
      # mutate wallet state. A structurally valid BEEF proves nothing about
      # whether the client actually broadcast — only ARC observation does.
      # Raising here (VerificationError 402 on "not visible", 503 on ARC
      # outage) keeps the exploit path in
      # +spec/e2e/brc121_gateway_e2e_spec.rb+ from ever reaching
      # +internalize_action+.
      #
      # When +@arc_client+ is nil we skip the check for backward
      # compatibility — runtime wiring of ARC + kill-switch semantics lives
      # in +Configuration+, not in this gateway.
      def verify_visibility!(txid)
        return unless @arc_client

        NetworkVisibility.verify!(
          arc_client: @arc_client,
          txid: txid,
          cache: @network_visibility_cache,
          logger: logger,
          visible_statuses: NetworkVisibility::VISIBLE_STATUSES
        )
      end

      def verify_payment_output!(transaction, output_index, required_sats)
        output = transaction.outputs[output_index]
        raise VerificationError.new("output index #{output_index} out of range", status: 400) unless output
        if output.satoshis < required_sats
          raise VerificationError.new("insufficient payment: #{output.satoshis} < #{required_sats}",
                                      status: 402)
        end

        output.satoshis
      end

      def internalize_payment!(beef_b64:, output_index:, derivation_prefix:, derivation_suffix:, sender_identity_key:)
        tx_bytes = Base64.strict_decode64(beef_b64).unpack("C*")
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
                                     description: "BRC-121 payment"
                                   })
      rescue VerificationError
        raise
      rescue StandardError => e
        # Log the full error server-side; return a generic message to the
        # client to avoid leaking wallet internals (paths, key derivation
        # state, storage errors) in the HTTP response body.
        logger.error "[brc121] internalize_action failed: #{e.class}: #{e.message}"
        raise VerificationError.new("payment internalisation failed", status: 402)
      end

      # §5 step 5: check the wallet's internalisation result for replay
      # (isMerge) and acceptance. The Ruby wallet does not yet expose
      # isMerge, but when it does this check will activate automatically.
      def check_internalization_result!(result)
        return unless result.is_a?(Hash)

        # §5 step 5: "If isMerge is true, the transaction was already known
        # to the wallet, indicating a replayed payment."
        is_merge = result[:is_merge] || result["isMerge"]
        raise VerificationError.new("replay: wallet reports transaction already internalised", status: 402) if is_merge

        # Guard against a wallet that returns an explicit rejection without raising.
        return unless result.key?(:accepted) || result.key?("accepted")

        accepted = result[:accepted] || result["accepted"]
        raise VerificationError.new("payment internalisation rejected by wallet", status: 402) unless accepted
      end

      def build_settlement_result(transaction, paid_sats)
        SettlementResult.new(
          receipt_headers: { "x-bsv-payment-satoshis-paid" => paid_sats.to_s },
          txid: transaction.txid_hex,
          network: X402.configuration.network
        )
      end

      # --- Settlement logging (tagged [brc121]) ---

      def logger
        X402.configuration.logger
      end

      def log_settlement_success(transaction, paid_sats, required_sats)
        logger.info "[brc121] Settlement OK: txid=#{transaction.txid_hex} " \
                    "paid=#{paid_sats} required=#{required_sats}"
      end
    end
  end
end
