# frozen_string_literal: true

require_relative "x402/version"
require_relative "x402/errors"
require_relative "x402/settlement_result"
require_relative "x402/configuration"
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
