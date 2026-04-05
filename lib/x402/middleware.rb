# frozen_string_literal: true

require "rack"
require "json"

module X402
  # Pure Rack dispatcher for payment-gated HTTP.
  #
  # The middleware has no blockchain knowledge — it matches routes, issues
  # payment challenges by polling configured gateways, and dispatches proofs
  # to the matching gateway for settlement.
  #
  # @example config.ru
  #   X402.configure do |config|
  #     config.domain = "api.example.com"
  #     config.server_wif = ENV["SERVER_WIF"]
  #     config.arc_url = "https://arc.taal.com"
  #     config.enable :pay_gateway
  #     config.protect method: :GET, path: "/api/expensive", amount_sats: 100
  #   end
  #
  #   use X402::Middleware
  class Middleware
    # @param app [#call] next Rack app in the middleware stack
    def initialize(app)
      @app = app
    end

    # @param env [Hash] Rack environment
    # @return [Array(Integer, Hash, Array)] Rack response triple
    def call(env)
      request = Rack::Request.new(env)
      config = X402.configuration
      route = config.find_route(request.request_method, request.path_info)

      # Unprotected route — pass through
      return @app.call(env) unless route

      # BRC-104 §6.2: extract client identity key from x-bsv-auth-identity-key
      extract_brc103_identity_key!(env)

      # Check for a proof/payment header from any gateway
      gateway, header_name, proof_payload = detect_proof(env, config)

      if gateway
        settle_and_forward(env, gateway, header_name, proof_payload, request, route)
      else
        issue_challenge(request, route, config)
      end
    end

    private

    def detect_proof(env, config)
      config.gateways.each do |gw|
        gw.proof_header_names.each do |name|
          rack_key = rack_header_key(name)
          value = env[rack_key]
          return [gw, name, value] if value && !value.empty?
        end
      end
      nil
    end

    # Challenge response body follows BRC-105 §6.2 format.
    # Settlement errors (e.g. underpayment 402, bad request 400) use the
    # generic {"error": reason} shape via error_response — these are
    # distinct: the challenge tells the client what to pay, whereas a
    # settlement error explains why a submitted payment was rejected.
    def issue_challenge(request, route, config)
      headers = { "content-type" => "application/json" }

      config.gateways.each do |gw|
        gw.challenge_headers(request, route).each do |name, value|
          headers[name.downcase] = value
        end
      end

      body = JSON.generate(
        status: "error",
        code: "ERR_PAYMENT_REQUIRED",
        satoshisRequired: route.resolve_amount_sats,
        description: "A BSV payment is required to access this resource."
      )
      [402, headers, [body]]
    end

    def settle_and_forward(env, gateway, header_name, proof_payload, request, route)
      result = gateway.settle!(header_name, proof_payload, request, route)

      status, headers, body = @app.call(env)

      # Merge any receipt headers from the gateway
      if result.respond_to?(:receipt_headers) && result.receipt_headers
        result.receipt_headers.each do |name, value|
          headers[name.downcase] = value
        end
      end

      [status, headers, body]
    rescue X402::VerificationError => e
      error_response(e.status, e.reason)
    rescue X402::Error => e
      error_response(400, e.message)
    rescue StandardError
      error_response(500, "internal error")
    end

    def error_response(status, reason)
      body = JSON.generate({ error: reason })
      [status, { "content-type" => "application/json" }, [body]]
    end

    # BRC-104 §6.2: x-bsv-auth-identity-key carries the client's public
    # identity key (33-byte compressed secp256k1 pubkey, hex). Populate
    # brc103.identity_key in the Rack env so gateways can use it as the
    # counterparty in BRC-42 key derivation.
    def extract_brc103_identity_key!(env)
      key = env["HTTP_X_BSV_AUTH_IDENTITY_KEY"]
      env["brc103.identity_key"] = key if key && !key.empty?
    end

    def rack_header_key(http_header_name)
      "HTTP_#{http_header_name.upcase.tr("-", "_")}"
    end
  end
end
