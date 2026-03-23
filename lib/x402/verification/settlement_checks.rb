# frozen_string_literal: true

require "base64"

module X402
  module Verification
    module SettlementChecks
      module_function

      def decode_transaction(proof)
        raw = Base64.decode64(proof.rawtx_b64)
        BSV::Transaction::Transaction.from_binary(raw)
      rescue StandardError => e
        raise VerificationError, "failed to decode transaction: #{e.message}"
      end

      def check_txid!(transaction, proof)
        return if transaction.txid_hex == proof.txid

        raise VerificationError, "txid mismatch: expected #{proof.txid}, got #{transaction.txid_hex}"
      end

      def check_nonce_input!(transaction, challenge)
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

      def check_payment_output!(transaction, route, config)
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

      def broadcast_if_configured!(transaction, config)
        return unless config.arc_url

        arc = BSV::Network::ARC.new(config.arc_url, api_key: config.arc_api_key)
        arc.broadcast(transaction)
      rescue StandardError => e
        raise VerificationError, "broadcast failed: #{e.message}"
      end
    end
  end
end
