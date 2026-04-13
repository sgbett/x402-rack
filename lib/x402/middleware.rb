# frozen_string_literal: true

require "rack"
require "json"
require_relative "status_endpoint"

module X402
  # Pure Rack dispatcher for payment-gated HTTP.
  #
  # The middleware has no blockchain knowledge — it matches routes, issues
  # payment challenges by polling configured gateways, and dispatches proofs
  # to the matching gateway for settlement.
  #
  # @example config.ru
  #   X402.configure { |c| c.operator_wallet_url = "https://..." }
  #   use X402::Middleware
  #
  # @see X402::Configuration for full configuration options
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

      if config.status_endpoint_enabled? && request.path_info == config.status_endpoint_path
        return X402::StatusEndpoint.new(config).call(env)
      end

      route = config.find_route(request.request_method, request.path_info)

      # Unprotected route — pass through
      return @app.call(env) unless route

      log = config.logger
      log.info "[x402] #{request.request_method} #{request.path_info} " \
               "— protected route, #{route.resolve_amount_sats} sats"

      # BRC-104 §6.2: extract client identity key from x-bsv-auth-identity-key
      extract_brc103_identity_key!(env, log)

      # Check for a proof/payment header from any gateway
      gateway, header_name, proof_payload = detect_proof(env, config)

      if gateway
        log.info "[x402] Proof header #{header_name} detected — dispatching to #{gateway.class.name}"
        settle_and_forward(env, gateway, header_name, proof_payload, request, route, log)
      else
        log.info "[x402] No proof header — issuing 402 challenge"
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
    rescue X402::VerificationError => e
      # Gateways may surface operational failures during challenge
      # issuance (e.g. ProofGateway raising 503 when its challenge
      # store is saturated). Preserve the intended status rather than
      # letting it bubble to a generic 500.
      config.logger.warn "[x402] Challenge issuance failed: #{e.status} #{e.reason}"
      error_response(e.status, e.reason)
    end

    def settle_and_forward(env, gateway, header_name, proof_payload, request, route, log)
      result = gateway.settle!(header_name, proof_payload, request, route)

      log.info "[x402] Settlement OK — txid=#{result.txid}"

      status, headers, body = @app.call(env)

      # Merge any receipt headers from the gateway
      if result.respond_to?(:receipt_headers) && result.receipt_headers
        result.receipt_headers.each do |name, value|
          headers[name.downcase] = value
        end
      end

      [status, headers, body]
    rescue X402::VerificationError => e
      log.warn "[x402] Settlement failed: #{e.status} #{e.reason}"
      error_response(e.status, e.reason)
    rescue X402::Error => e
      log.warn "[x402] Error: #{e.message}"
      error_response(400, e.message)
    rescue StandardError => e
      log.error "[x402] Unexpected error: #{e.class}: #{e.message}"
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
    #
    # NOTE: This is the CLAIMED identity key — not authenticated. BRC-103
    # signature verification must occur in a separate middleware if identity
    # assertions are required for authorisation decisions.
    #
    # Does not overwrite an identity key already set by upstream middleware
    # (e.g. a BRC-103/104 auth layer that has verified the signature).
    def extract_brc103_identity_key!(env, log)
      return if env["brc103.identity_key"].is_a?(String) && !env["brc103.identity_key"].empty?

      key = env["HTTP_X_BSV_AUTH_IDENTITY_KEY"]
      if key && !key.empty?
        log.info "[x402] Client identity key: #{key[0..15]}..."
        env["brc103.identity_key"] = key.downcase
      else
        log.debug "[x402] No x-bsv-auth-identity-key header"
      end
    end

    def rack_header_key(http_header_name)
      "HTTP_#{http_header_name.upcase.tr("-", "_")}"
    end
  end
end
