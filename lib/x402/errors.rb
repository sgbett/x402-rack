# frozen_string_literal: true

module X402
  class Error < StandardError; end

  class ConfigurationError < Error; end

  class VerificationError < Error
    attr_reader :reason, :status

    def initialize(reason, status: 400)
      @reason = reason
      @status = status
      super(reason)
    end
  end
end
