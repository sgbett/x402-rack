# frozen_string_literal: true

require "base64"

module X402
  module Base64Url
    module_function

    def encode(data)
      Base64.urlsafe_encode64(data, padding: false)
    end

    def decode(data)
      Base64.urlsafe_decode64(data)
    rescue ArgumentError
      raise X402::Error, "invalid base64url encoding"
    end
  end
end
