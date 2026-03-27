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
    # Client broadcasts, server checks mempool. Nonce-bound, request-binding.
    class ProofGateway < Gateway
      # @param nonce_provider [#call] callable returning nonce UTXO hash
      # @param arc_client [#query] ARC client for mempool queries
      # @param payee_locking_script_hex [String, nil] payee script (falls back to config)
      def initialize(nonce_provider:, arc_client:, payee_locking_script_hex: nil, wallet: nil)
        super(payee_locking_script_hex: payee_locking_script_hex, wallet: wallet)
        @nonce_provider = nonce_provider
        @arc_client = arc_client
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

      def build_merkleworks_challenge(rack_request, route)
        nonce = @nonce_provider.call(rack_request)
        config = X402.configuration

        Challenge.new(
          version: Challenge::CURRENT_VERSION,
          scheme: Challenge::SUPPORTED_SCHEMES.first,
          domain: config.domain,
          method: rack_request.request_method,
          path: rack_request.path_info,
          query: rack_request.query_string,
          req_headers_sha256: RequestBinding.headers_sha256(rack_request),
          req_body_sha256: RequestBinding.body_sha256(rack_request),
          amount_sats: route.amount_sats,
          payee_locking_script_hex: derive_payee_hex,
          nonce_txid: nonce[:txid],
          nonce_vout: nonce[:vout],
          nonce_satoshis: nonce[:satoshis],
          nonce_locking_script_hex: nonce[:locking_script_hex],
          expires_at: Time.now.to_i + Challenge::DEFAULT_TTL
        )
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
        verify_payment_output!(transaction, route, challenge.payee_locking_script_hex)
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
        nonce_txid_bytes = [challenge.nonce_txid].pack("H*").reverse

        found = transaction.inputs.any? do |input|
          input.prev_tx_id == nonce_txid_bytes &&
            input.prev_tx_out_index == challenge.nonce_vout
        end

        return if found

        raise VerificationError, "nonce UTXO not spent in transaction"
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
        @arc_client.query(txid)
      rescue StandardError => e
        raise VerificationError.new("mempool check failed: #{e.message}", status: 502)
      end
    end
  end
end
