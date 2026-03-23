# frozen_string_literal: true

require "json/canonicalization"

require_relative "x402/version"
require_relative "x402/errors"
require_relative "x402/protocol/base64url"
require_relative "x402/protocol/request_binding"
require_relative "x402/configuration"
require_relative "x402/protocol/challenge"
require_relative "x402/protocol/proof"
require_relative "x402/verification/protocol_checks"
require_relative "x402/verification/settlement_checks"
require_relative "x402/verification/pipeline"
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
