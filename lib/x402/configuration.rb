# frozen_string_literal: true

require "securerandom"
require_relative "remote_wallet"

module X402
  # DSL for configuring X402 middleware, gateways, and protected routes.
  #
  # @example Minimal configuration
  #   X402.configure do |config|
  #     config.domain = "api.example.com"
  #     config.server_wif = ENV["SERVER_WIF"]
  #     config.arc_url = "https://arc.taal.com"
  #     config.enable :pay_gateway
  #     config.protect method: :GET, path: "/api/expensive", amount_sats: 100
  #   end
  class Configuration
    # Route holds a raw +amount_sats+ that may be an Integer or a callable.
    # The +resolve_amount_sats+ method evaluates callables at access time,
    # enabling fiat-denominated pricing with live exchange rates.
    Route = Struct.new(:http_method, :path, :amount_sats, :arc_wait_for, keyword_init: true) do
      # Resolves +amount_sats+ — if it's a callable (Proc/Lambda),
      # it is evaluated each time to get the current sats amount.
      def resolve_amount_sats
        amount_sats.respond_to?(:call) ? amount_sats.call : amount_sats
      end
    end

    GATEWAY_METHODS = %i[challenge_headers proof_header_names settle!].freeze

    PAY_GATEWAY_KNOWN_OPTS = %i[
      arc_client payee_locking_script_hex arc_wait_for arc_timeout
      binding_mode wallet challenge_secret settlement_worker txid_store
    ].freeze

    PROOF_GATEWAY_KNOWN_OPTS = %i[
      arc_client payee_locking_script_hex nonce_provider
      wallet challenge_secret
    ].freeze

    BRC105_GATEWAY_KNOWN_OPTS = %i[
      wallet key_deriver server_wif server_key prefix_store
    ].freeze

    BRC121_GATEWAY_KNOWN_OPTS = %i[wallet txid_store].freeze

    GATEWAY_REGISTRY = {
      pay_gateway: "X402::BSV::PayGateway",
      proof_gateway: "X402::BSV::ProofGateway",
      brc105_gateway: "X402::BSV::BRC105Gateway",
      brc121_gateway: "X402::BSV::BRC121Gateway"
    }.freeze

    # Gateways auto-enabled when +wallet:+ is set and no explicit
    # +enable+ or +gateways=+ calls were made. Both work zero-config
    # with a BRC-100 wallet and expose non-overlapping proof headers.
    DEFAULT_GATEWAYS = %i[pay_gateway brc121_gateway].freeze

    VALID_NETWORKS = %w[bsv:mainnet bsv:testnet].freeze
    DEFAULT_NETWORK = "bsv:mainnet"

    attr_accessor :domain, :payee_locking_script_hex, :gateways,
                  :arc_url, :arc_api_key, :arc_client, :server_wif, :wallet,
                  :operator_wallet_url, :exchange_rate_provider, :logger,
                  :status_endpoint_path, :status_endpoint_token
    attr_reader :routes, :gateway_specs, :network

    DEFAULT_STATUS_ENDPOINT_PATH = "/_x402/status"

    def initialize
      @routes = []
      @gateways = []
      @gateway_specs = []
      @network = DEFAULT_NETWORK
      @logger = default_logger
      @status_endpoint_enabled = false
      @status_endpoint_path = DEFAULT_STATUS_ENDPOINT_PATH
      @status_endpoint_token = nil
    end

    # Opt in to the read-only status endpoint at +status_endpoint_path+
    # (default +/_x402/status+). Disabled by default.
    #
    # The endpoint is always bearer-token authenticated. If
    # +status_endpoint_token+ is unset at +validate!+ time, a random token
    # is generated and logged once at startup so it can be copied into a
    # +curl+ command. Production deployments should set
    # +status_endpoint_token+ explicitly (typically from an environment
    # variable) to suppress auto-generation.
    #
    # @return [void]
    def enable_status_endpoint
      @status_endpoint_enabled = true
    end

    # @return [Boolean] whether the status endpoint should be served
    def status_endpoint_enabled?
      @status_endpoint_enabled
    end

    # Set the BSV network explicitly.
    #
    # @param value [String] e.g. "bsv:mainnet" or "bsv:testnet"
    def network=(value)
      @network = value
      @network_explicit = true
    end

    private

    def default_logger
      require "logger"
      logger = ::Logger.new($stderr)
      logger.formatter = proc { |_sev, _time, _prog, msg| "#{msg}\n" }
      logger.level = ::Logger::DEBUG
      logger
    end

    public

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
    # from +arc_url+ (and optional +arc_api_key+), falling back to
    # +ARC.default+ when no explicit URL is configured.
    #
    # @return [BSV::Network::ARC]
    def shared_arc_client
      return @arc_client if @arc_client

      @shared_arc_client ||= build_arc_client
    end

    # Returns the shared wallet used by all gateways for key derivation
    # (BRC-42/43) and, where supported, payment internalisation.
    #
    # Resolution order:
    #   1. An explicitly-set +@wallet+ (any BRC-100 compatible wallet,
    #      typically a +BSV::Wallet::WalletClient+), or a +RemoteWallet+
    #      auto-constructed from +operator_wallet_url+
    #   2. A +ProtoWallet+ built from +server_wif+ (backwards compat)
    #   3. +nil+ if neither is set
    #
    # @return [BSV::Wallet::ProtoWallet, BSV::Wallet::WalletClient, RemoteWallet, nil]
    def shared_wallet
      return @wallet if @wallet
      return if @server_wif.nil? || @server_wif.empty?

      @shared_wallet ||= build_wallet
    end

    # Register a protected route.
    #
    # @param method [String] HTTP method or "*" for any
    # @param path [String, Regexp] exact path or pattern
    # @param amount_sats [Integer, #call] required payment in satoshis.
    #   Accepts a static Integer or a callable (Proc/Lambda) that returns
    #   the current sats amount at challenge time. Use a callable for
    #   fiat-denominated pricing with live exchange rates.
    # @param amount_usd [Numeric, nil] convenience — price in USD, resolved
    #   to sats at challenge time via +exchange_rate_provider+. Mutually
    #   exclusive with +amount_sats+.
    # @param arc_wait_for [String, Symbol, nil] per-route ARC settlement override.
    #   +nil+ (default) uses the gateway's +arc_wait_for+ setting.
    #   A string value (e.g. +"SEEN_ON_NETWORK"+, +"MINED"+) overrides the
    #   gateway default for synchronous broadcast.
    #   +:async+ validates the transaction locally then enqueues it for
    #   background settlement via the gateway's +settlement_worker+, returning
    #   200 immediately without waiting for ARC confirmation.
    def protect(method:, path:, amount_sats: nil, amount_usd: nil, arc_wait_for: nil)
      sats = resolve_amount(amount_sats, amount_usd)
      @routes << Route.new(http_method: method.upcase, path: path, amount_sats: sats, arc_wait_for: arc_wait_for)
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

    # Validate the configuration and construct gateways from specs.
    #
    # Called automatically at the end of +X402.configure+. Builds gateways
    # from +enable+ specs, validates all constraints, and emits operational
    # warnings for development defaults.
    #
    # @raise [ConfigurationError] if required fields are missing or invalid
    def validate!
      raise ConfigurationError, "domain is required" if domain.nil? || domain.empty?

      resolve_network!
      resolve_operator_wallet!
      validate_payee_source!
      auto_enable_default_gateways! if should_auto_enable_defaults?
      build_gateways_from_specs! if gateways.empty? && !gateway_specs.empty?
      validate_gateways!
      warn_operational_concerns!
      finalise_status_endpoint!
      raise ConfigurationError, "at least one route must be protected" if routes.empty?
    end

    private

    # Resolve the network identifier.
    #
    # Resolution order:
    #   1. Explicit +config.network =+ (wins if set)
    #   2. +BSV_NETWORK+ environment variable
    #   3. +DEFAULT_NETWORK+ ("bsv:mainnet")
    #
    # Blank or empty values at any level are treated as unset and fall
    # through to the next source.
    def resolve_network!
      @network = resolve_network_value
      return if VALID_NETWORKS.include?(@network)

      raise ConfigurationError,
            "invalid network #{@network.inspect} — must be one of: #{VALID_NETWORKS.join(", ")}"
    end

    def resolve_network_value
      return @network if @network_explicit && @network.is_a?(String) && !@network.empty?

      env_val = ENV.fetch("BSV_NETWORK", nil)
      return env_val if env_val.is_a?(String) && !env_val.empty?

      DEFAULT_NETWORK
    end

    # Construct a RemoteWallet from +operator_wallet_url+ when set.
    #
    # Mutually exclusive with +wallet+ and +server_wif+ — raises
    # ConfigurationError if more than one wallet source is provided.
    def resolve_operator_wallet!
      return unless operator_wallet_url_present?

      validate_wallet_source_exclusivity!
      @wallet = RemoteWallet.new(url: @operator_wallet_url)
    end

    def validate_wallet_source_exclusivity!
      has_wallet = !@wallet.nil?
      has_server_wif = @server_wif && !@server_wif.empty?

      if has_wallet
        raise ConfigurationError,
              "operator_wallet_url and wallet are mutually exclusive — provide only one"
      end

      return unless has_server_wif

      raise ConfigurationError,
            "operator_wallet_url and server_wif are mutually exclusive — provide only one"
    end

    def operator_wallet_url_present?
      @operator_wallet_url.is_a?(String) && !@operator_wallet_url.empty?
    end

    # Resolve and announce the status endpoint token. Auto-generates a
    # random token if none was provided so the endpoint is always
    # authenticated. Logged at startup so developers can copy it into a
    # +curl+ command.
    def finalise_status_endpoint!
      return unless @status_endpoint_enabled

      autogenerated = false
      if @status_endpoint_token.nil? || @status_endpoint_token.to_s.empty?
        @status_endpoint_token = SecureRandom.hex(16)
        autogenerated = true
      end

      logger.info "[x402] status endpoint enabled at #{@status_endpoint_path}"
      return unless autogenerated

      logger.info "[x402] status endpoint token (auto-generated): #{@status_endpoint_token}"
      logger.info "[x402]   curl -H 'Authorization: Bearer #{@status_endpoint_token}' " \
                  "http://localhost:PORT#{@status_endpoint_path}"
      logger.info "[x402]   set status_endpoint_token explicitly (e.g. from ENV) to suppress auto-generation"
    end

    def warn_operational_concerns!
      return if gateway_specs.empty? # gateways= was used directly — specs not relevant

      warn_ephemeral_challenge_secret!
      warn_in_memory_prefix_store!
    end

    def warn_ephemeral_challenge_secret!
      secret_gateways = %w[X402::BSV::PayGateway X402::BSV::ProofGateway]
      needs_warning = gateway_specs.any? do |class_name, options|
        secret_gateways.include?(class_name) && !options[:challenge_secret]
      end
      return unless needs_warning

      logger.warn "[x402] challenge_secret is auto-generated. " \
                  "In-flight challenges will fail after process restart. " \
                  "Set challenge_secret: explicitly for production."
    end

    def warn_in_memory_prefix_store!
      needs_warning = gateway_specs.any? do |class_name, options|
        class_name == "X402::BSV::BRC105Gateway" && !options[:prefix_store]
      end
      return unless needs_warning

      logger.warn "[x402] BRC105Gateway using in-memory PrefixStore. " \
                  "No replay protection across processes. " \
                  "Use a shared backend (Redis) for multi-process deployments."
    end

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

    def resolve_amount(amount_sats, amount_usd)
      raise ConfigurationError, "amount_sats and amount_usd are mutually exclusive" if amount_sats && amount_usd

      return amount_sats if amount_sats

      raise ConfigurationError, "protect requires amount_sats: or amount_usd:" unless amount_usd
      unless exchange_rate_provider
        raise ConfigurationError, "amount_usd requires exchange_rate_provider to be configured"
      end
      unless exchange_rate_provider.respond_to?(:sats_for)
        raise ConfigurationError, "exchange_rate_provider must respond to #sats_for(currency, amount)"
      end

      provider = exchange_rate_provider
      usd = amount_usd
      -> { provider.sats_for("USD", usd) }
    end

    def validate_payee_source!
      has_payee = payee_locking_script_hex && !payee_locking_script_hex.empty?
      has_server_wif = @server_wif && !@server_wif.empty?
      has_wallet = !@wallet.nil?
      has_operator_url = operator_wallet_url_present?

      return if has_payee || has_server_wif || has_wallet || has_operator_url

      raise ConfigurationError, "wallet, server_wif, operator_wallet_url, or payee_locking_script_hex is required"
    end

    # Auto-enables default gateways when a +wallet+ has been set and the
    # caller has not explicitly enabled any gateways.
    #
    # Both +BRC121Gateway+ and +PayGateway+ are auto-enabled. ARC is
    # always available via +ARC.default+ so PayGateway no longer requires
    # an explicit +arc_url+.
    def should_auto_enable_defaults?
      !@wallet.nil? && gateway_specs.empty? && (gateways.nil? || gateways.empty?)
    end

    def auto_enable_default_gateways!
      enable(:brc121_gateway)
      enable(:pay_gateway) if arc_available?
    end

    def arc_available?
      true
    end

    def build_arc_client
      if arc_url && !arc_url.empty?
        ::BSV::Network::ARC.new(arc_url, api_key: arc_api_key)
      else
        logger.info "[x402] using default ARC broadcaster (GorillaPool Arcade)"
        ::BSV::Network::ARC.default(testnet: @network == "bsv:testnet")
      end
    end

    def build_wallet
      key = ::BSV::Primitives::PrivateKey.from_wif(@server_wif)
      ::BSV::Wallet::ProtoWallet.new(key)
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
        when "X402::BSV::BRC121Gateway" then build_brc121_gateway(klass, options)
        end
      end
    end

    def build_pay_gateway(klass, options)
      reject_unknown_options!(:pay_gateway, options, PAY_GATEWAY_KNOWN_OPTS)
      wallet = options[:wallet] || shared_wallet
      opts = { arc_client: options[:arc_client] || shared_arc_client }
      opts[:payee_locking_script_hex] = options[:payee_locking_script_hex] || payee_locking_script_hex
      opts[:wallet] = wallet if wallet
      %i[arc_wait_for arc_timeout binding_mode challenge_secret settlement_worker txid_store].each do |key|
        opts[key] = options[key] if options.key?(key)
      end
      klass.new(**opts)
    end

    def build_proof_gateway(klass, options)
      reject_unknown_options!(:proof_gateway, options, PROOF_GATEWAY_KNOWN_OPTS)

      raise ConfigurationError, "proof_gateway requires nonce_provider:" unless options.key?(:nonce_provider)

      opts = { arc_client: options[:arc_client] || shared_arc_client,
               payee_locking_script_hex: options[:payee_locking_script_hex] || payee_locking_script_hex,
               nonce_provider: options[:nonce_provider] }

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

      key_deriver = if options.key?(:key_deriver)
                      options[:key_deriver]
                    elsif options.key?(:server_wif)
                      ::BSV::Wallet::KeyDeriver.new(::BSV::Primitives::PrivateKey.from_wif(options[:server_wif]))
                    elsif options.key?(:server_key)
                      ::BSV::Wallet::KeyDeriver.new(options[:server_key])
                    elsif shared_wallet
                      shared_wallet.key_deriver
                    end

      unless key_deriver
        raise ConfigurationError,
              "brc105_gateway requires one of: key_deriver:, server_wif:, server_key:, or top-level server_wif"
      end

      wallet = options[:wallet] || shared_wallet
      unless wallet
        raise ConfigurationError,
              "brc105_gateway requires wallet: (or top-level config.wallet = / config.server_wif =)"
      end

      klass.new(
        key_deriver: key_deriver,
        prefix_store: options[:prefix_store] || X402::BSV::PrefixStore::Memory.new,
        wallet: wallet
      )
    end

    def build_brc121_gateway(klass, options)
      reject_unknown_options!(:brc121_gateway, options, BRC121_GATEWAY_KNOWN_OPTS)
      wallet = options[:wallet] || @wallet
      unless wallet
        raise ConfigurationError,
              "brc121_gateway requires wallet: (or top-level config.wallet =)"
      end

      opts = { wallet: wallet }
      opts[:txid_store] = options[:txid_store] if options.key?(:txid_store)
      klass.new(**opts)
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
