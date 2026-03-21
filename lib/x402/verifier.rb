# frozen_string_literal: true

require "base64"

module X402
  module Verifier
    module_function

    # Run the ordered verification pipeline.
    # Raises VerificationError on failure.
    # Returns the decoded BSV transaction on success.
    def verify!(proof, challenge:, rack_request:, route:, config:)
      # Step 3: Version supported
      unless challenge.version == Challenge::CURRENT_VERSION
        raise VerificationError, "unsupported version: #{challenge.version}"
      end

      # Step 4: Scheme supported
      unless Challenge::SUPPORTED_SCHEMES.include?(challenge.scheme)
        raise VerificationError, "unsupported scheme: #{challenge.scheme}"
      end

      # Step 5: Challenge hash matches proof
      raise VerificationError, "challenge hash mismatch" unless challenge.sha256_hex == proof.challenge_sha256

      # Step 6: Request binding
      verify_request_binding!(challenge, rack_request)

      # Step 7: Expiration
      raise VerificationError.new("challenge expired", status: 402) if challenge.expires_at <= Time.now.to_i

      # Step 8: Decode transaction
      tx = decode_transaction(proof)

      # Step 9: txid matches
      unless tx.txid_hex == proof.txid
        raise VerificationError, "txid mismatch: expected #{proof.txid}, got #{tx.txid_hex}"
      end

      # Step 10: Nonce UTXO spent as input
      verify_nonce_input!(tx, challenge)

      # Step 11: Output pays sufficient amount to payee
      verify_payment_output!(tx, route, config)

      # Step 12: Optional mempool acceptance
      broadcast_if_configured!(tx, config)

      tx
    end

    private_class_method def self.verify_request_binding!(challenge, rack_request)
      raise VerificationError, "request method mismatch" unless challenge.method == rack_request.request_method

      raise VerificationError, "request path mismatch" unless challenge.path == rack_request.path_info

      raise VerificationError, "request query mismatch" unless challenge.query == rack_request.query_string

      expected_body = RequestBinding.body_sha256(rack_request)
      raise VerificationError, "request body hash mismatch" unless challenge.req_body_sha256 == expected_body

      expected_headers = RequestBinding.headers_sha256(rack_request)
      return if challenge.req_headers_sha256 == expected_headers

      raise VerificationError, "request headers hash mismatch"
    end

    private_class_method def self.decode_transaction(proof)
      raw = Base64.decode64(proof.rawtx_b64)
      BSV::Transaction::Transaction.from_binary(raw)
    rescue StandardError => e
      raise VerificationError, "failed to decode transaction: #{e.message}"
    end

    private_class_method def self.verify_nonce_input!(transaction, challenge)
      # prev_tx_id is stored in wire byte order (natural hash).
      # challenge.nonce_txid is display byte order (hex), so we convert.
      nonce_txid_bytes = [challenge.nonce_txid].pack("H*").reverse

      found = transaction.inputs.any? do |input|
        input.prev_tx_id == nonce_txid_bytes &&
          input.prev_tx_out_index == challenge.nonce_vout
      end

      return if found

      raise VerificationError, "nonce UTXO not spent in transaction"
    end

    private_class_method def self.verify_payment_output!(transaction, route, config)
      payee_script = BSV::Script::Script.from_hex(config.payee_locking_script_hex)

      found = transaction.outputs.any? do |output|
        output.locking_script == payee_script &&
          output.satoshis >= route.amount_sats
      end

      return if found

      raise VerificationError.new(
        "no output pays >= #{route.amount_sats} sats to payee",
        status: 402
      )
    end

    private_class_method def self.broadcast_if_configured!(transaction, config)
      return unless config.arc_url

      arc = BSV::Network::ARC.new(config.arc_url, api_key: config.arc_api_key)
      arc.broadcast(transaction)
    rescue StandardError => e
      raise VerificationError, "broadcast failed: #{e.message}"
    end
  end
end
