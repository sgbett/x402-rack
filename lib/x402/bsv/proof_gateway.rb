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
    # - Profile A (no nonce_key): challenge includes nonce UTXO metadata only
    # - Profile B (with nonce_key): challenge includes pre-signed template with
    #   nonce input at index 0 signed with 0xC3
    class ProofGateway < Gateway # rubocop:disable Metrics/ClassLength
      NONCE_SIGHASH = ::BSV::Transaction::Sighash::SINGLE_FORK_ID_ANYONE_CAN_PAY

      # @param nonce_provider [#call] callable returning nonce UTXO hash
      # @param arc_client [#status] ARC client for mempool queries
      # @param nonce_key [BSV::Primitives::PrivateKey, nil] key for signing nonce input (Profile B)
      # @param payee_locking_script_hex [String, nil] payee script (falls back to config)
      def initialize(nonce_provider:, arc_client:, nonce_key: nil,
                     payee_locking_script_hex: nil, wallet: nil, challenge_secret: nil)
        super(payee_locking_script_hex: payee_locking_script_hex, wallet: wallet,
              challenge_secret: challenge_secret)
        @nonce_provider = nonce_provider
        @arc_client = arc_client
        @nonce_key = nonce_key
      end

      def challenge_headers(rack_request, route)
        challenge = build_merkleworks_challenge(rack_request, route)
        { "X402-Challenge" => challenge.to_header }
      end

      def proof_header_names
        ["X402-Proof"]
      end

      def settle!(_header_name, proof_payload, rack_request, route)
        proof = Proof.from_header(proof_payload)
        challenge = reconstruct_challenge(rack_request)
        run_protocol_checks!(challenge, proof, rack_request)
        decode_and_verify_transaction!(proof, challenge, route)
        check_mempool!(proof.txid)

        SettlementResult.new(txid: proof.txid, network: "bsv:mainnet")
      end

      private

      # Build a Profile B template: nonce input (signed 0xC3) + payment + OP_RETURN.
      # Falls back to base class (Profile A) when nonce_key is nil.
      def build_proof_template(rack_request, route, nonce)
        return super(rack_request, route) unless @nonce_key

        validate_nonce_key!(nonce)

        tx = ::BSV::Transaction::Transaction.new

        # Input 0: nonce UTXO (will be signed with 0xC3)
        nonce_script = ::BSV::Script::Script.from_hex(nonce[:locking_script_hex])
        nonce_input = ::BSV::Transaction::TransactionInput.new(
          prev_tx_id: [nonce[:txid]].pack("H*").reverse,
          prev_tx_out_index: nonce[:vout]
        )
        nonce_input.source_satoshis = nonce[:satoshis]
        nonce_input.source_locking_script = nonce_script
        tx.add_input(nonce_input)

        # Output 0: payment (committed by 0xC3 signature)
        payee_hex = derive_payee_hex
        payee_script = ::BSV::Script::Script.from_hex(payee_hex)
        tx.add_output(::BSV::Transaction::TransactionOutput.new(
                        satoshis: route.amount_sats,
                        locking_script: payee_script
                      ))

        # Output 1: OP_RETURN binding (not committed by SIGHASH_SINGLE on input 0)
        binding_hash = request_binding_hash(rack_request)
        tx.add_output(::BSV::Transaction::TransactionOutput.new(
                        satoshis: 0,
                        locking_script: build_op_return_script(binding_hash)
                      ))

        # Sign input 0 with 0xC3
        tx.sign(0, @nonce_key, NONCE_SIGHASH)

        [tx, payee_hex]
      end

      def build_merkleworks_challenge(rack_request, route)
        nonce = @nonce_provider.call(rack_request)
        config = X402.configuration
        payee_hex = derive_payee_hex

        # Build template if Profile B
        template, = build_proof_template(rack_request, route, nonce) if @nonce_key

        attrs = {
          version: Challenge::CURRENT_VERSION,
          scheme: Challenge::SUPPORTED_SCHEMES.first,
          domain: config.domain,
          method: rack_request.request_method,
          path: rack_request.path_info,
          query: rack_request.query_string,
          req_headers_sha256: RequestBinding.headers_sha256(rack_request),
          req_body_sha256: RequestBinding.body_sha256(rack_request),
          amount_sats: route.amount_sats,
          payee_locking_script_hex: payee_hex,
          nonce_txid: nonce[:txid],
          nonce_vout: nonce[:vout],
          nonce_satoshis: nonce[:satoshis],
          nonce_locking_script_hex: nonce[:locking_script_hex],
          expires_at: Time.now.to_i + Challenge::DEFAULT_TTL
        }

        # Profile B: include pre-signed template (not part of canonical hash)
        attrs[:partial_tx_b64] = Base64.strict_encode64(template.to_binary) if template

        Challenge.new(attrs)
      end

      def reconstruct_challenge(rack_request)
        challenge_header = rack_request.env["HTTP_X402_CHALLENGE"]
        if challenge_header.nil? || challenge_header.empty?
          raise VerificationError.new("missing X402-Challenge header", status: 400)
        end

        Challenge.from_header(challenge_header)
      end

      def run_protocol_checks!(challenge, proof, rack_request)
        Verification::ProtocolChecks.check_version!(challenge)
        Verification::ProtocolChecks.check_scheme!(challenge)
        Verification::ProtocolChecks.check_challenge_hash!(challenge, proof)
        Verification::ProtocolChecks.check_request_binding!(challenge, rack_request)
        Verification::ProtocolChecks.check_expiry!(challenge)
      end

      def decode_and_verify_transaction!(proof, challenge, route)
        transaction = decode_transaction(proof)
        check_txid!(transaction, proof)
        check_nonce_input!(transaction, challenge)
        verify_nonce_provenance!(transaction, challenge) if @nonce_key
        server_payee_hex = resolve_static_payee_hex
        verify_payment_output!(transaction, route, server_payee_hex)
        transaction
      end

      def decode_transaction(proof)
        raw = Base64.decode64(proof.rawtx_b64)
        ::BSV::Transaction::Transaction.from_binary(raw)
      rescue StandardError => e
        raise VerificationError, "failed to decode transaction: #{e.message}"
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
      rescue StandardError => e
        raise VerificationError, "nonce provenance check failed: #{e.message}"
      end

      def verify_payment_output!(transaction, route, payee_hex)
        payee_script = payee_script_from_hex(payee_hex)
        found = transaction.outputs.any? do |output|
          output.locking_script == payee_script && output.satoshis >= route.amount_sats
        end
        return if found

        raise VerificationError.new("no output pays >= #{route.amount_sats} sats to payee", status: 402)
      end

      def check_mempool!(txid)
        @arc_client.status(txid)
      rescue StandardError => e
        raise VerificationError.new("mempool check failed: #{e.message}", status: 502)
      end

      # Validate that the nonce key matches the nonce UTXO's P2PKH locking script
      def validate_nonce_key!(nonce)
        expected_h160 = @nonce_key.public_key.hash160.unpack1("H*")
        expected_script = "76a914#{expected_h160}88ac"
        return if nonce[:locking_script_hex] == expected_script

        raise X402::ConfigurationError,
              "nonce_key does not match nonce UTXO locking script"
      end
    end
  end
end
