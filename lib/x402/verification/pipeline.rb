# frozen_string_literal: true

module X402
  module Verification
    module Pipeline
      module_function

      # Run the ordered verification pipeline.
      # Raises VerificationError on failure.
      # Returns the decoded BSV transaction on success.
      def verify!(proof, challenge:, rack_request:, route:, config:)
        ProtocolChecks.check_version!(challenge)
        ProtocolChecks.check_scheme!(challenge)
        ProtocolChecks.check_challenge_hash!(challenge, proof)
        ProtocolChecks.check_request_binding!(challenge, rack_request)
        ProtocolChecks.check_expiry!(challenge)

        tx = SettlementChecks.decode_transaction(proof)
        SettlementChecks.check_txid!(tx, proof)
        SettlementChecks.check_nonce_input!(tx, challenge)
        SettlementChecks.check_payment_output!(tx, route, config)
        SettlementChecks.broadcast_if_configured!(tx, config)

        tx
      end
    end
  end
end
