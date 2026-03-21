# frozen_string_literal: true

require "openssl"

module X402
  # Computes canonical hashes of request headers and body for binding
  # challenges and proofs to the actual HTTP request.
  module RequestBinding
    module_function

    # Compute SHA-256 hex digest of the request body.
    # Returns the hash of an empty string if no body is present.
    def body_sha256(rack_request)
      return sha256_hex("") unless rack_request.body

      rack_request.body.rewind if rack_request.body.respond_to?(:rewind)
      body = rack_request.body.read || ""
      rack_request.body.rewind if rack_request.body.respond_to?(:rewind)
      sha256_hex(body)
    end

    # Compute SHA-256 hex digest of canonical request headers.
    # For v1, this is the empty string hash (no headers bound).
    def headers_sha256(_rack_request)
      sha256_hex("")
    end

    def sha256_hex(data)
      OpenSSL::Digest::SHA256.hexdigest(data)
    end
  end
end
