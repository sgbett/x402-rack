# frozen_string_literal: true

require "rack"
require "json"

module X402
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      request = Rack::Request.new(env)
      config = X402.configuration
      route = config.find_route(request.request_method, request.path_info)

      # Unprotected route — pass through
      return @app.call(env) unless route

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

    def issue_challenge(request, route, config)
      headers = { "content-type" => "application/json" }

      config.gateways.each do |gw|
        gw.challenge_headers(request, route).each do |name, value|
          headers[name.downcase] = value
        end
      end

      body = JSON.generate({ error: "Payment Required" })
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

    def rack_header_key(http_header_name)
      "HTTP_#{http_header_name.upcase.tr("-", "_")}"
    end
  end
end
