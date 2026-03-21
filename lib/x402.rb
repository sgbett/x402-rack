# frozen_string_literal: true

require_relative "x402/version"
require_relative "x402/errors"
require_relative "x402/base64url"
require_relative "x402/canonical_json"
require_relative "x402/request_binding"
require_relative "x402/configuration"
require_relative "x402/challenge"
require_relative "x402/proof"
require_relative "x402/verifier"
require_relative "x402/middleware"

module X402
  class << self
    def configure
      yield(configuration)
      configuration.validate!
    end

    def configuration
      @configuration ||= Configuration.new
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
