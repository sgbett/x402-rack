# frozen_string_literal: true

require "rack"
require "json"

RSpec.describe X402::Middleware do
  let(:inner_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] } }
  let(:app) { described_class.new(inner_app) }

  # Mock gateway implementing the three-method interface
  let(:mock_gateway) do
    gw = Object.new

    def gw.challenge_headers(_request, _route)
      { "X402-Challenge" => "dGVzdC1jaGFsbGVuZ2U" }
    end

    def gw.proof_header_names
      ["X402-Proof"]
    end

    settlement_result = X402::SettlementResult.new(
      receipt_headers: {},
      txid: "aa" * 32,
      network: "bsv:mainnet"
    )

    gw.define_singleton_method(:settle!) do |_header_name, _proof, _request, _route|
      settlement_result
    end

    gw
  end

  let(:pay_gateway) do
    gw = Object.new

    def gw.challenge_headers(_request, _route)
      { "Payment-Required" => "eyJ0ZXN0IjogdHJ1ZX0" }
    end

    def gw.proof_header_names
      ["Payment-Signature"]
    end

    settlement_result = X402::SettlementResult.new(
      receipt_headers: { "Payment-Response" => "eyJzdWNjZXNzIjogdHJ1ZX0" },
      txid: "bb" * 32,
      network: "bsv:mainnet"
    )

    gw.define_singleton_method(:settle!) do |_header_name, _proof, _request, _route|
      settlement_result
    end

    gw
  end

  before do
    X402.reset_configuration!
    X402.configure do |c|
      c.domain = "api.example.com"
      c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
      c.gateways = [mock_gateway]
      c.protect(method: "GET", path: "/premium", amount_sats: 50)
    end
  end

  after { X402.reset_configuration! }

  describe "unprotected routes" do
    it "passes through to the app" do
      env = Rack::MockRequest.env_for("/free", method: "GET")
      status, _headers, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "challenge issuance" do
    it "returns 402 with gateway challenge headers when no proof present" do
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      status, headers, body = app.call(env)

      expect(status).to eq(402)
      expect(headers["x402-challenge"]).to eq("dGVzdC1jaGFsbGVuZ2U")
      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to eq("Payment Required")
    end

    it "includes challenge headers from all gateways" do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [mock_gateway, pay_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      status, headers, = app.call(env)

      expect(status).to eq(402)
      expect(headers["x402-challenge"]).not_to be_nil
      expect(headers["payment-required"]).not_to be_nil
    end

    it "skips gateways that return empty challenge headers" do
      declining_gw = Object.new
      def declining_gw.challenge_headers(*, **)
        {}
      end

      def declining_gw.proof_header_names
        ["X-Declined"]
      end

      def declining_gw.settle!(*); end

      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [declining_gw, mock_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      _, headers, = app.call(env)

      expect(headers["x402-challenge"]).not_to be_nil
      expect(headers).not_to have_key("x-declined")
    end
  end

  describe "proof dispatch" do
    it "dispatches to the matching gateway and forwards to app" do
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X402_PROOF"] = "valid-proof-data"

      status, _headers, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end

    it "dispatches to the correct gateway when multiple are configured" do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [mock_gateway, pay_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "payment-data"

      status, headers, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
      expect(headers["payment-response"]).to eq("eyJzdWNjZXNzIjogdHJ1ZX0")
    end

    it "includes receipt headers in the response" do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [pay_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "payment-data"

      _, headers, = app.call(env)
      expect(headers["payment-response"]).to eq("eyJzdWNjZXNzIjogdHJ1ZX0")
    end

    it "re-issues challenge when proof header matches no gateway" do
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X_UNKNOWN_PROOF"] = "some-data"

      status, headers, = app.call(env)
      expect(status).to eq(402)
      expect(headers["x402-challenge"]).not_to be_nil
    end
  end

  describe "settlement errors" do
    it "returns the error status from VerificationError" do
      failing_gw = Object.new
      def failing_gw.challenge_headers(*, **)
        { "X402-Challenge" => "test" }
      end

      def failing_gw.proof_header_names
        ["X402-Proof"]
      end

      def failing_gw.settle!(*)
        raise X402::VerificationError.new("insufficient payment", status: 402)
      end

      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [failing_gw]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X402_PROOF"] = "proof-data"

      status, _, body = app.call(env)
      expect(status).to eq(402)
      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to eq("insufficient payment")
    end

    it "returns 500 for unexpected errors" do
      exploding_gw = Object.new
      def exploding_gw.challenge_headers(*, **)
        { "X402-Challenge" => "test" }
      end

      def exploding_gw.proof_header_names
        ["X402-Proof"]
      end

      def exploding_gw.settle!(*)
        raise "something broke"
      end

      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [exploding_gw]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X402_PROOF"] = "proof-data"

      status, _, body = app.call(env)
      expect(status).to eq(500)
      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to eq("internal error")
    end
  end

  describe "BRC-105 gateway integration" do
    let(:brc105_gateway) do
      gw = Object.new

      def gw.challenge_headers(_request, _route)
        {
          "x-bsv-payment-satoshis-required" => "1000",
          "x-bsv-payment-derivation-prefix" => "abc123",
          "x-bsv-payment-identity-key" => "02#{"ff" * 32}"
        }
      end

      def gw.proof_header_names
        ["x-bsv-payment"]
      end

      settlement_result = X402::SettlementResult.new(
        receipt_headers: { "x-bsv-payment-result" => "eyJzdWNjZXNzIjp0cnVlfQ" },
        txid: "cc" * 32,
        network: "bsv:mainnet"
      )

      gw.define_singleton_method(:settle!) do |_header_name, _proof, _request, _route|
        settlement_result
      end

      gw
    end

    it "includes x-bsv-* challenge headers alongside other gateway headers" do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [mock_gateway, pay_gateway, brc105_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      status, headers, = app.call(env)

      expect(status).to eq(402)
      expect(headers["x402-challenge"]).not_to be_nil
      expect(headers["payment-required"]).not_to be_nil
      expect(headers["x-bsv-payment-satoshis-required"]).to eq("1000")
      expect(headers["x-bsv-payment-derivation-prefix"]).to eq("abc123")
      expect(headers["x-bsv-payment-identity-key"]).not_to be_nil
    end

    it "dispatches to BRC105Gateway when x-bsv-payment header is present" do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [mock_gateway, pay_gateway, brc105_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X_BSV_PAYMENT"] = '{"derivationPrefix":"abc","derivationSuffix":"def","transaction":"..."}'

      status, headers, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
      expect(headers["x-bsv-payment-result"]).to eq("eyJzdWNjZXNzIjp0cnVlfQ")
    end

    it "has no proof header collision with Pay/Proof gateways" do
      proof_headers = [mock_gateway, pay_gateway, brc105_gateway].flat_map(&:proof_header_names)
      expect(proof_headers).to eq(proof_headers.uniq)
    end
  end

  describe "boundary test" do
    it "works with any object implementing the gateway interface" do
      custom_gw = Class.new do
        def challenge_headers(_request, _route)
          { "X-Custom-Challenge" => "custom-data" }
        end

        def proof_header_names
          ["X-Custom-Proof"]
        end

        def settle!(_header_name, _proof, _request, _route)
          X402::SettlementResult.new(txid: "custom-tx")
        end
      end.new

      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [custom_gw]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      # Challenge
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      status, headers, = app.call(env)
      expect(status).to eq(402)
      expect(headers["x-custom-challenge"]).to eq("custom-data")

      # Settlement
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X_CUSTOM_PROOF"] = "custom-proof"
      status, _, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end
end
