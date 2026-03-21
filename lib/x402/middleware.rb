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

      proof_header = env["HTTP_X402_PROOF"]
      challenge_header = env["HTTP_X402_CHALLENGE"]

      # No proof — issue a challenge
      return issue_challenge(request, route, config) if proof_header.nil? || proof_header.empty?

      # Proof present — verify
      verify_and_forward(env, request, proof_header, challenge_header, route, config)
    end

    private

    def issue_challenge(request, route, config)
      challenge = Challenge.build(request, route: route, config: config)

      body = JSON.generate({
                             error: "Payment Required",
                             challenge: challenge.to_h
                           })

      [
        402,
        {
          "content-type" => "application/json",
          "x402-challenge" => challenge.to_header
        },
        [body]
      ]
    end

    def verify_and_forward(env, request, proof_header, challenge_header, route, config)
      # Step 1: Decode proof
      proof = Proof.from_header(proof_header)

      # Step 2: Decode echoed challenge
      return error_response(400, "missing X402-Challenge header") if challenge_header.nil? || challenge_header.empty?

      challenge = Challenge.from_header(challenge_header)

      # Run verification pipeline
      Verifier.verify!(proof, challenge: challenge, rack_request: request, route: route, config: config)

      # Verification passed — forward to app
      @app.call(env)
    rescue X402::VerificationError => e
      error_response(e.status, e.reason)
    rescue X402::Error => e
      error_response(400, e.message)
    end

    def error_response(status, reason)
      body = JSON.generate({ error: reason })
      [status, { "content-type" => "application/json" }, [body]]
    end
  end
end
