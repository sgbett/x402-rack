# frozen_string_literal: true

require "base64"
require "json"
require "json/canonicalization"
require_relative "../protocol/base64url"
require_relative "../protocol/request_binding"
require_relative "../protocol/challenge"
require_relative "../protocol/proof"
require_relative "../verification/protocol_checks"

module X402
  module BSV
    # Merkleworks x402 compatible gateway.
    #
    # Challenge: X402-Challenge (merkleworks JSON with nonce UTXO + request binding)
    # Proof:     X402-Proof (echoed challenge hash + rawtx + txid)
    #
    # Supports two modes:
    # - Profile A: challenge includes nonce UTXO metadata only
    # - Profile B: nonce_provider returns a pre-signed partial_tx template
    class ProofGateway < Gateway
      # ARC status values that confirm ARC knows about the tx and hasn't
      # rejected it. ARC progresses a broadcast tx through roughly:
      #
      #   RECEIVED → STORED → ANNOUNCED_TO_NETWORK →
      #   REQUESTED_BY_NETWORK → SENT_TO_NETWORK →
      #   ACCEPTED_BY_NETWORK → SEEN_ON_NETWORK → MINED
      #
      # Any of these mean "ARC has the tx and is processing it"; the
      # client has demonstrably broadcast. The bad states we must reject
      # are UNKNOWN (never seen), REJECTED, DOUBLE_SPEND_ATTEMPTED —
      # anything in this whitelist is acceptable.
      #
      # Bitcoin's single-spend guarantee at the network layer is the
      # actual replay gate; this check just confirms the client fulfilled
      # their broadcast obligation. Matches the merkleworks reference
      # implementation's `visible` check.
      ACCEPTABLE_MEMPOOL_STATUSES = %w[
        RECEIVED
        STORED
        ANNOUNCED_TO_NETWORK
        REQUESTED_BY_NETWORK
        SENT_TO_NETWORK
        ACCEPTED_BY_NETWORK
        SEEN_ON_NETWORK
        MINED
      ].freeze

      # Mempool polling retry schedule. ARC typically returns an
      # intermediate status (RECEIVED, STORED, SENT_TO_NETWORK) for a
      # brief window after broadcast before progressing to
      # SEEN_ON_NETWORK. A short retry loop absorbs that race without
      # adding stateful polling infrastructure.
      MEMPOOL_RETRY_DELAYS_SECONDS = [0.25, 0.5, 1.0].freeze

      # @param nonce_provider [#call] callable returning nonce UTXO hash;
      #   receives (rack_request, payee:, amount:) kwargs.
      #   Profile B providers include :partial_tx (binary) in the response.
      # @param arc_client [#status] ARC client for mempool queries
      # @param payee_locking_script_hex [String, nil] payee script (falls back to config)
      # @param challenge_store [#store!, #lookup, #consume!] per-instance
      #   challenge cache (default: in-memory, per-process).
      def initialize(nonce_provider:, arc_client:,
                     payee_locking_script_hex: nil, wallet: nil, challenge_secret: nil,
                     challenge_store: nil)
        super(payee_locking_script_hex: payee_locking_script_hex, wallet: wallet,
              challenge_secret: challenge_secret)
        @nonce_provider = nonce_provider
        @arc_client = arc_client
        @challenge_store = challenge_store || ChallengeStore::Memory.new
      end

      # Build a 402 challenge with merkleworks +X402-Challenge+ header.
      #
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [Hash] challenge headers
      # @raise [ConfigurationError] if route uses callable amount_sats (fiat pricing)
      def challenge_headers(rack_request, route)
        if route.amount_sats.respond_to?(:call)
          raise ConfigurationError,
                "proof_gateway does not support callable amount_sats (fiat pricing) — use a static value"
        end
        challenge = build_merkleworks_challenge(rack_request, route)
        begin
          @challenge_store.store!(challenge.sha256_hex, challenge)
        rescue ChallengeStore::StoreFullError
          raise VerificationError.new("server at capacity — try again later", status: 503)
        end
        { "X402-Challenge" => challenge.to_header }
      end

      # @return [Array<String>] proof header names this gateway responds to
      def proof_header_names
        ["X402-Proof"]
      end

      # Verify a merkleworks x402 proof against the challenge and check mempool.
      #
      # @param _header_name [String] which proof header matched
      # @param proof_payload [String] base64url-encoded proof
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [SettlementResult]
      # @raise [VerificationError] on invalid proof, binding mismatch, or mempool failure
      def settle!(_header_name, proof_payload, rack_request, route)
        required_sats = route.resolve_amount_sats
        proof = Proof.from_header(proof_payload)
        challenge = lookup_challenge!(proof)
        run_protocol_checks!(challenge, proof, rack_request)
        decode_and_verify_transaction!(proof, challenge, required_sats)
        check_mempool!(proof.txid)
        consume_challenge!(proof)

        SettlementResult.new(txid: proof.txid, network: X402.configuration.network)
      end

      private

      # Recover the original server-issued challenge from the cache, keyed
      # by the hash the client echoes in the proof. This is the provenance
      # gate: the attacker cannot populate this store, so a proof
      # referencing a forged challenge will miss and be rejected.
      def lookup_challenge!(proof)
        if proof.challenge_sha256.nil? || proof.challenge_sha256.empty?
          raise VerificationError.new("missing challenge_sha256 in proof", status: 400)
        end

        challenge = @challenge_store.lookup(proof.challenge_sha256)
        return challenge if challenge

        raise VerificationError.new("challenge not found or expired", status: 400)
      end

      # Atomically remove the challenge after a successful settlement.
      # consume! is the replay gate: it returns false if another thread
      # consumed the entry between our lookup_challenge! and here, in
      # which case the other thread already succeeded and this one must
      # lose the race. A second attempt with the same proof (whether
      # serial or concurrent) will always see exactly one success.
      def consume_challenge!(proof)
        return if @challenge_store.consume!(proof.challenge_sha256)

        raise VerificationError.new("challenge not found or expired", status: 400)
      end

      def build_merkleworks_challenge(rack_request, route)
        config = X402.configuration
        required_sats = route.resolve_amount_sats
        payee_hex = derive_payee_hex

        nonce = @nonce_provider.call(rack_request, payee: payee_hex, amount: required_sats)

        # Profile B: provider returns a pre-signed partial_tx (binary)
        template_binary = nonce[:partial_tx]

        attrs = {
          version: Challenge::CURRENT_VERSION,
          scheme: Challenge::SUPPORTED_SCHEMES.first,
          domain: config.domain,
          method: rack_request.request_method,
          path: rack_request.path_info,
          query: rack_request.query_string,
          req_headers_sha256: RequestBinding.headers_sha256(rack_request),
          req_body_sha256: RequestBinding.body_sha256(rack_request),
          amount_sats: required_sats,
          payee_locking_script_hex: payee_hex,
          nonce_txid: nonce[:txid],
          nonce_vout: nonce[:vout],
          nonce_satoshis: nonce[:satoshis],
          nonce_locking_script_hex: nonce[:locking_script_hex],
          expires_at: Time.now.to_i + Challenge::DEFAULT_TTL
        }

        if template_binary
          # Deserialise the treasury's template and append OP_RETURN
          tx = ::BSV::Transaction::Transaction.from_binary(template_binary)
          binding_hash = request_binding_hash(rack_request)
          tx.add_output(::BSV::Transaction::TransactionOutput.new(
                          satoshis: 0,
                          locking_script: build_op_return_script(binding_hash)
                        ))
          attrs[:partial_tx_b64] = Base64.strict_encode64(tx.to_binary)
        end

        Challenge.new(attrs)
      end

      def run_protocol_checks!(challenge, proof, rack_request)
        Verification::ProtocolChecks.check_version!(challenge)
        Verification::ProtocolChecks.check_scheme!(challenge)
        Verification::ProtocolChecks.check_challenge_hash!(challenge, proof)
        Verification::ProtocolChecks.check_request_binding!(challenge, rack_request)
        Verification::ProtocolChecks.check_expiry!(challenge)
      end

      def decode_and_verify_transaction!(proof, challenge, required_sats)
        transaction = decode_transaction(proof)
        check_txid!(transaction, proof)
        check_nonce_input!(transaction, challenge)
        verify_nonce_provenance!(transaction, challenge) if challenge.partial_tx_b64
        server_payee_hex = resolve_static_payee_hex
        verify_payment_output!(transaction, required_sats, server_payee_hex)
        transaction
      end

      def decode_transaction(proof)
        raw = Base64.decode64(proof.rawtx_b64)
        ::BSV::Transaction::Transaction.from_binary(raw)
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError, "failed to decode transaction"
      end

      def check_txid!(transaction, proof)
        return if transaction.txid_hex == proof.txid

        raise VerificationError, "txid mismatch: expected #{proof.txid}, got #{transaction.txid_hex}"
      end

      def check_nonce_input!(transaction, challenge)
        input = transaction.inputs[0]
        raise VerificationError, "no inputs in transaction" unless input

        nonce_txid_bytes = [challenge.nonce_txid].pack("H*").reverse
        return if input.prev_tx_id == nonce_txid_bytes && input.prev_tx_out_index == challenge.nonce_vout

        raise VerificationError, "nonce UTXO must be at input index 0"
      end

      # Profile B: verify the nonce input signature cryptographically.
      # Sets source info on input 0 (required for BIP-143 sighash) and
      # runs the full P2PKH script verification via the SDK interpreter.
      def verify_nonce_provenance!(transaction, challenge)
        input = transaction.inputs[0]
        raise VerificationError, "nonce must be at input index 0" unless input

        # BIP-143 sighash needs the source UTXO details
        input.source_satoshis = challenge.nonce_satoshis
        input.source_locking_script = ::BSV::Script::Script.from_hex(challenge.nonce_locking_script_hex)

        unless transaction.verify_input(0)
          raise VerificationError, "nonce signature verification failed: input 0 not validly signed"
        end
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError, "nonce provenance check failed"
      end

      def verify_payment_output!(transaction, required_sats, payee_hex)
        payee_script = payee_script_from_hex(payee_hex)
        found = transaction.outputs.any? do |output|
          output.locking_script == payee_script && output.satoshis >= required_sats
        end
        return if found

        raise VerificationError.new("no output pays >= #{required_sats} sats to payee", status: 402)
      end

      # Poll ARC for the tx status, retrying briefly to absorb the
      # propagation lag between broadcast and SEEN_ON_NETWORK. Returns
      # on the first acceptable status; raises if no attempt succeeds.
      def check_mempool!(txid)
        attempts = MEMPOOL_RETRY_DELAYS_SECONDS.length + 1
        last_status = nil

        attempts.times do |i|
          last_status = @arc_client.status(txid).tx_status
          break if ACCEPTABLE_MEMPOOL_STATUSES.include?(last_status)

          sleep(MEMPOOL_RETRY_DELAYS_SECONDS[i]) if i < MEMPOOL_RETRY_DELAYS_SECONDS.length
        end

        return if ACCEPTABLE_MEMPOOL_STATUSES.include?(last_status)

        raise VerificationError.new(
          "transaction not yet visible in mempool (last status: #{last_status || "unknown"})",
          status: 402
        )
      rescue VerificationError
        raise
      rescue StandardError
        raise VerificationError.new("mempool check failed", status: 502)
      end
    end
  end
end
