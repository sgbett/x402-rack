# frozen_string_literal: true

require "json"

module X402
  class Proof
    attr_reader :challenge_sha256, :payment

    def initialize(challenge_sha256:, payment:)
      @challenge_sha256 = challenge_sha256
      @payment = payment
    end

    # Parse a proof from the X402-Proof header (base64url-encoded JSON).
    def self.from_header(header_value)
      json = Base64Url.decode(header_value)
      data = JSON.parse(json, symbolize_names: true)

      new(
        challenge_sha256: data[:challenge_sha256],
        payment: data[:payment]
      )
    rescue JSON::ParserError
      raise X402::Error, "invalid proof JSON"
    end

    # Convenience accessors for payment fields.
    def rawtx_b64
      @payment&.fetch(:rawtx_b64, nil)
    end

    def txid
      @payment&.fetch(:txid, nil)
    end
  end
end
