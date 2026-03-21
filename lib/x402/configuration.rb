# frozen_string_literal: true

module X402
  class Configuration
    Route = Struct.new(:http_method, :path, :amount_sats, keyword_init: true)

    attr_accessor :domain, :payee_locking_script_hex, :nonce_provider, :arc_url, :arc_api_key
    attr_reader :routes

    def initialize
      @routes = []
      @arc_url = nil
      @arc_api_key = nil
    end

    # Register a protected route.
    #
    # @param method [String] HTTP method or "*" for any
    # @param path [String, Regexp] exact path or pattern
    # @param amount_sats [Integer] required payment in satoshis
    def protect(method:, path:, amount_sats:)
      @routes << Route.new(http_method: method.upcase, path: path, amount_sats: amount_sats)
    end

    # Find the matching route for a request method and path.
    #
    # @return [Route, nil]
    def find_route(request_method, request_path)
      @routes.find do |route|
        method_matches?(route.http_method, request_method) &&
          path_matches?(route.path, request_path)
      end
    end

    def validate!
      raise ConfigurationError, "domain is required" if domain.nil? || domain.empty?

      if payee_locking_script_hex.nil? || payee_locking_script_hex.empty?
        raise ConfigurationError,
              "payee_locking_script_hex is required"
      end
      raise ConfigurationError, "nonce_provider is required" unless nonce_provider.respond_to?(:call)
      raise ConfigurationError, "at least one route must be protected" if routes.empty?
    end

    private

    def method_matches?(route_method, request_method)
      route_method == "*" || route_method == request_method.upcase
    end

    def path_matches?(route_path, request_path)
      case route_path
      when Regexp then route_path.match?(request_path)
      when String then route_path == request_path
      else false
      end
    end
  end
end
