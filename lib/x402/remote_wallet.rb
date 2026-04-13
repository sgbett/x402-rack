# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module X402
  # HTTP client adapter implementing the duck-typed wallet interface by
  # calling a remote @bsv/simple server wallet API.
  #
  # Provides the same interface as BSV::Wallet::WalletClient:
  #   - +#get_public_key(identity_key:)+ — fetches the identity key
  #   - +#get_public_key(protocol_id:, key_id:, ...)+ — derives a key
  #   - +#internalize_action(tx:, outputs:, description:)+ — relays payment
  #
  # Thread-safe: all mutable state is protected by a Mutex.
  class RemoteWallet
    DEFAULT_TIMEOUT = 10 # seconds

    # @param url [String] base URL of the remote wallet API
    # @param timeout [Integer] HTTP timeout in seconds (default 10)
    def initialize(url:, timeout: DEFAULT_TIMEOUT)
      raise ConfigurationError, "remote wallet url is required" if url.nil? || url.to_s.empty?

      @base_uri = URI.parse(url)
      @timeout = timeout
      @identity_key = nil
      @mutex = Mutex.new
    rescue URI::InvalidURIError => e
      raise ConfigurationError, "invalid remote wallet url: #{e.message}"
    end

    # Fetch a public key from the remote wallet.
    #
    # When +identity_key: true+, returns the wallet's identity public key
    # (cached after first call). Otherwise, delegates to the remote wallet
    # for BRC-42/43 key derivation.
    #
    # Matches ProtoWallet interface: accepts a positional Hash of arguments.
    # Also supports keyword arguments for convenience (used by tests and
    # direct callers).
    #
    # @param args [Hash] arguments hash (ProtoWallet style)
    # @return [Hash] +{ public_key: "hex" }+
    def get_public_key(args = {}, **kwargs)
      args = kwargs unless kwargs.empty?
      if args[:identity_key]
        fetch_identity_key
      else
        fetch_derived_key(protocol_id: args[:protocol_id], key_id: args[:key_id], counterparty: args[:counterparty])
      end
    end

    # Relay a settled payment to the remote wallet for internalisation.
    #
    # Matches ProtoWallet interface: accepts a positional Hash of arguments.
    # Also supports keyword arguments for convenience.
    #
    # @param args [Hash] arguments hash (ProtoWallet style)
    # @return [Hash] the wallet's response
    def internalize_action(args = {}, **kwargs)
      args = kwargs unless kwargs.empty?
      output = args[:outputs]&.first || {}
      remittance = output[:payment_remittance] || {}

      body = {
        tx: args[:tx],
        description: args[:description] || "",
        senderIdentityKey: remittance[:sender_identity_key],
        derivationPrefix: remittance[:derivation_prefix],
        derivationSuffix: remittance[:derivation_suffix],
        outputIndex: output[:output_index]
      }

      response = post_request("receive", body)
      parse_json_response!(response, context: "internalize_action")
    end

    private

    def fetch_identity_key
      cached = @mutex.synchronize { @identity_key }
      return { public_key: cached } if cached

      response = get_request("create")
      data = parse_json_response!(response, context: "get_public_key(identity_key)")

      key = extract_identity_key(data)
      @mutex.synchronize { @identity_key = key }
      { public_key: key }
    end

    def fetch_derived_key(protocol_id:, key_id:, counterparty:)
      params = { action: "getPublicKey" }
      params[:protocolId] = Array(protocol_id).join(",") if protocol_id
      params[:keyId] = key_id if key_id
      params[:counterparty] = counterparty if counterparty

      uri = build_uri(params)
      response = get_request_uri(uri)
      data = parse_json_response!(response, context: "get_public_key(derived)")

      key = extract_derived_key(data)
      { public_key: key }
    end

    # --- HTTP helpers --------------------------------------------------------

    def get_request(action)
      uri = build_uri(action: action)
      get_request_uri(uri)
    end

    def get_request_uri(uri)
      request = Net::HTTP::Get.new(uri)
      execute_request(uri, request)
    end

    def post_request(action, body)
      uri = build_uri(action: action)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
      execute_request(uri, request)
    end

    def execute_request(uri, request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.request(request)
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ECONNRESET,
           Net::OpenTimeout, SocketError => e
      raise ConfigurationError, "remote wallet unreachable at #{@base_uri}: #{e.message}"
    rescue Net::ReadTimeout => e
      raise ConfigurationError, "remote wallet timed out at #{@base_uri}: #{e.message}"
    end

    def build_uri(params)
      uri = @base_uri.dup
      existing = URI.decode_www_form(uri.query || "")
      params.each { |k, v| existing << [k.to_s, v.to_s] }
      uri.query = URI.encode_www_form(existing)
      uri
    end

    # --- Response parsing ----------------------------------------------------

    def parse_json_response!(response, context:)
      unless response.is_a?(Net::HTTPSuccess)
        raise ConfigurationError,
              "remote wallet #{context} failed: HTTP #{response.code} #{response.message}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise ConfigurationError, "remote wallet returned invalid JSON for #{context}: #{e.message}"
    end

    def extract_identity_key(data)
      # The @bsv/simple create response returns the identity key as
      # "serverIdentityKey" at the top level. Other implementations may
      # use "identityKey", "publicKey", or "identity_key".
      key = data["serverIdentityKey"] || data["identityKey"] || data["publicKey"] || data["identity_key"]
      raise ConfigurationError, "remote wallet did not return an identity key" if key.nil? || key.to_s.empty?

      key
    end

    def extract_derived_key(data)
      # The request endpoint may return the derived key under various names.
      key = data["publicKey"] || data["public_key"] || data["derivedPublicKey"]
      raise ConfigurationError, "remote wallet did not return a derived public key" if key.nil? || key.to_s.empty?

      key
    end
  end
end
