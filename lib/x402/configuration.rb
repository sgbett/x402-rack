# frozen_string_literal: true

module X402
  class Configuration
    Route = Struct.new(:http_method, :path, :amount_sats, keyword_init: true)

    GATEWAY_METHODS = %i[challenge_headers proof_header_names settle!].freeze

    PAY_GATEWAY_KNOWN_OPTS = %i[
      arc_client payee_locking_script_hex arc_wait_for arc_timeout
      binding_mode wallet challenge_secret
    ].freeze

    PROOF_GATEWAY_KNOWN_OPTS = %i[
      arc_client payee_locking_script_hex nonce_provider nonce_key
      nonce_wif wallet challenge_secret
    ].freeze

    BRC105_GATEWAY_KNOWN_OPTS = %i[
      arc_client key_deriver server_wif server_key prefix_store
    ].freeze

    GATEWAY_REGISTRY = {
      pay_gateway: "X402::BSV::PayGateway",
      proof_gateway: "X402::BSV::ProofGateway",
      brc105_gateway: "X402::BSV::BRC105Gateway"
    }.freeze

    attr_accessor :domain, :payee_locking_script_hex, :gateways,
                  :arc_url, :arc_api_key, :arc_client
    attr_reader :routes, :gateway_specs

    def initialize
      @routes = []
      @gateways = []
      @gateway_specs = []
    end

    # Record a gateway to be constructed later during +validate!+.
    #
    # @param name [Symbol] registered gateway name (e.g. +:pay_gateway+)
    # @param options [Hash] options forwarded to the gateway constructor
    # @raise [ConfigurationError] if the gateway name is not registered
    def enable(name, **options)
      class_name = GATEWAY_REGISTRY[name]
      raise ConfigurationError, "unknown gateway: #{name.inspect}" unless class_name

      @gateway_specs << [class_name, options]
    end

    # Returns a memoised ARC client instance. If +arc_client+ has been
    # injected directly, that takes precedence. Otherwise, builds one
    # from +arc_url+ (and optional +arc_api_key+).
    #
    # @return [BSV::Network::ARC]
    # @raise [ConfigurationError] if +arc_url+ is nil and no +arc_client+ injected
    def shared_arc_client
      return @arc_client if @arc_client

      @shared_arc_client ||= build_arc_client
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
      build_gateways_from_specs! if gateways.empty? && !gateway_specs.empty?
      validate_gateways!
      raise ConfigurationError, "at least one route must be protected" if routes.empty?
    end

    private

    def validate_gateways!
      raise ConfigurationError, "at least one gateway is required" if gateways.nil? || gateways.empty?

      gateways.each_with_index do |gw, i|
        GATEWAY_METHODS.each do |method|
          unless gw.respond_to?(method)
            raise ConfigurationError,
                  "gateway at index #{i} does not respond to ##{method}"
          end
        end
      end

      validate_no_duplicate_proof_headers!
    end

    def validate_no_duplicate_proof_headers!
      seen = {}
      gateways.each_with_index do |gw, i|
        gw.proof_header_names.each do |name|
          if seen.key?(name)
            raise ConfigurationError,
                  "duplicate proof header \"#{name}\" claimed by gateways at indices #{seen[name]} and #{i}"
          end
          seen[name] = i
        end
      end
    end

    def build_arc_client
      raise ConfigurationError, "arc_url is required (or inject arc_client directly)" if arc_url.nil? || arc_url.empty?

      ::BSV::Network::ARC.new(arc_url, api_key: arc_api_key)
    end

    def build_gateways_from_specs!
      require_relative "bsv"
      require "bsv-wallet"

      @gateways = gateway_specs.map do |class_name, options|
        klass = Object.const_get(class_name)
        case class_name
        when "X402::BSV::PayGateway" then build_pay_gateway(klass, options)
        when "X402::BSV::ProofGateway" then build_proof_gateway(klass, options)
        when "X402::BSV::BRC105Gateway" then build_brc105_gateway(klass, options)
        end
      end
    end

    def build_pay_gateway(klass, options)
      reject_unknown_options!(:pay_gateway, options, PAY_GATEWAY_KNOWN_OPTS)
      opts = { arc_client: options[:arc_client] || shared_arc_client,
               payee_locking_script_hex: options[:payee_locking_script_hex] || payee_locking_script_hex }
      %i[arc_wait_for arc_timeout binding_mode wallet challenge_secret].each do |key|
        opts[key] = options[key] if options.key?(key)
      end
      klass.new(**opts)
    end

    def build_proof_gateway(klass, options) # rubocop:disable Metrics/PerceivedComplexity
      reject_unknown_options!(:proof_gateway, options, PROOF_GATEWAY_KNOWN_OPTS)

      raise ConfigurationError, "proof_gateway requires nonce_provider:" unless options.key?(:nonce_provider)

      if options.key?(:nonce_wif) && options.key?(:nonce_key)
        raise ConfigurationError, "proof_gateway: nonce_wif: and nonce_key: are mutually exclusive"
      end

      opts = { arc_client: options[:arc_client] || shared_arc_client,
               payee_locking_script_hex: options[:payee_locking_script_hex] || payee_locking_script_hex,
               nonce_provider: options[:nonce_provider] }

      if options.key?(:nonce_wif)
        opts[:nonce_key] = ::BSV::Primitives::PrivateKey.from_wif(options[:nonce_wif])
      elsif options.key?(:nonce_key)
        opts[:nonce_key] = options[:nonce_key]
      end

      %i[wallet challenge_secret].each do |key|
        opts[key] = options[key] if options.key?(key)
      end
      klass.new(**opts)
    end

    def build_brc105_gateway(klass, options) # rubocop:disable Metrics/PerceivedComplexity
      reject_unknown_options!(:brc105_gateway, options, BRC105_GATEWAY_KNOWN_OPTS)

      key_sources = %i[key_deriver server_wif server_key].select { |k| options.key?(k) }
      if key_sources.size > 1
        raise ConfigurationError,
              "brc105_gateway: #{key_sources.join(", ")} are mutually exclusive — provide only one"
      end
      if key_sources.empty?
        raise ConfigurationError,
              "brc105_gateway requires one of: key_deriver:, server_wif:, or server_key:"
      end

      key_deriver = if options.key?(:key_deriver)
                      options[:key_deriver]
                    elsif options.key?(:server_wif)
                      ::BSV::Wallet::KeyDeriver.new(::BSV::Primitives::PrivateKey.from_wif(options[:server_wif]))
                    else
                      ::BSV::Wallet::KeyDeriver.new(options[:server_key])
                    end

      klass.new(
        key_deriver: key_deriver,
        prefix_store: options[:prefix_store] || X402::BSV::PrefixStore::Memory.new,
        arc_client: options[:arc_client] || shared_arc_client
      )
    end

    # -- Option validation ---------------------------------------------------

    def reject_unknown_options!(gateway_name, options, known)
      unknown = options.keys - known
      return if unknown.empty?

      raise ConfigurationError,
            "#{gateway_name}: unknown option(s): #{unknown.map(&:inspect).join(", ")}"
    end

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
