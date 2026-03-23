# frozen_string_literal: true

module X402
  module Verification
    module ProtocolChecks
      module_function

      def check_version!(challenge)
        return if challenge.version == Challenge::CURRENT_VERSION

        raise VerificationError, "unsupported version: #{challenge.version}"
      end

      def check_scheme!(challenge)
        return if Challenge::SUPPORTED_SCHEMES.include?(challenge.scheme)

        raise VerificationError, "unsupported scheme: #{challenge.scheme}"
      end

      def check_challenge_hash!(challenge, proof)
        raise VerificationError, "challenge hash mismatch" unless challenge.sha256_hex == proof.challenge_sha256
      end

      def check_request_binding!(challenge, rack_request)
        raise VerificationError, "request method mismatch" unless challenge.method == rack_request.request_method
        raise VerificationError, "request path mismatch" unless challenge.path == rack_request.path_info
        raise VerificationError, "request query mismatch" unless challenge.query == rack_request.query_string

        expected_body = RequestBinding.body_sha256(rack_request)
        raise VerificationError, "request body hash mismatch" unless challenge.req_body_sha256 == expected_body

        expected_headers = RequestBinding.headers_sha256(rack_request)
        return if challenge.req_headers_sha256 == expected_headers

        raise VerificationError, "request headers hash mismatch"
      end

      def check_expiry!(challenge)
        raise VerificationError.new("challenge expired", status: 402) if challenge.expires_at <= Time.now.to_i
      end
    end
  end
end
