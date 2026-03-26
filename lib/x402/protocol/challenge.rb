# frozen_string_literal: true

require "json"
require "openssl"

module X402
  class Challenge
    CURRENT_VERSION = 1
    SUPPORTED_SCHEMES = ["bsv-tx-v1"].freeze
    DEFAULT_TTL = 300 # 5 minutes

    attr_reader :version, :scheme, :domain, :method, :path, :query,
                :req_headers_sha256, :req_body_sha256,
                :amount_sats, :payee_locking_script_hex,
                :nonce_txid, :nonce_vout, :nonce_satoshis, :nonce_locking_script_hex,
                :expires_at

    def initialize(attrs = {})
      attrs.each { |k, v| instance_variable_set(:"@#{k}", v) }
    end

    def to_h
      {
        version: @version,
        scheme: @scheme,
        domain: @domain,
        method: @method,
        path: @path,
        query: @query,
        req_headers_sha256: @req_headers_sha256,
        req_body_sha256: @req_body_sha256,
        amount_sats: @amount_sats,
        payee_locking_script_hex: @payee_locking_script_hex,
        nonce_txid: @nonce_txid,
        nonce_vout: @nonce_vout,
        nonce_satoshis: @nonce_satoshis,
        nonce_locking_script_hex: @nonce_locking_script_hex,
        expires_at: @expires_at
      }
    end

    def to_canonical_json
      to_h.to_json_c14n
    end

    def sha256_hex
      OpenSSL::Digest::SHA256.hexdigest(to_canonical_json)
    end

    def to_header
      Base64Url.encode(to_canonical_json)
    end

    # Reconstruct a challenge from the echoed X402-Challenge header.
    def self.from_header(header_value)
      json = Base64Url.decode(header_value)
      data = JSON.parse(json, symbolize_names: true)
      new(data)
    rescue JSON::ParserError => e
      raise X402::Error, "invalid challenge JSON: #{e.message}"
    end
  end
end
