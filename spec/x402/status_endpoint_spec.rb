# frozen_string_literal: true

require "rack"
require "json"

RSpec.describe X402::StatusEndpoint do
  # Deterministic test WIF (mainnet, not for any real funds)
  let(:test_wif) { "L1Knwj9W3qK3qMKdTvmg3VfzUs3ij2LETTFhxza9LfD5dngnoLG1" }
  let(:test_key) { BSV::Primitives::PrivateKey.from_wif(test_wif) }
  let(:test_pubkey_hex) { test_key.public_key.to_hex }
  let(:test_address) { test_key.public_key.address }

  let(:inner_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] } }
  let(:app) { X402::Middleware.new(inner_app) }

  let(:mock_gateway) do
    gw = Object.new
    def gw.challenge_headers(_req, _route) = { "X402-Challenge" => "x" }
    def gw.proof_header_names = ["X402-Proof"]
    def gw.settle!(*) = X402::SettlementResult.new(receipt_headers: {}, txid: "aa" * 32, network: "bsv:mainnet")
    gw
  end

  def configure_with(token: nil, enabled: true, path: nil)
    X402.reset_configuration!
    X402.configure do |c|
      c.domain = "api.example.com"
      c.server_wif = test_wif
      c.gateways = [mock_gateway]
      c.protect(method: "GET", path: "/premium", amount_sats: 50)
      c.enable_status_endpoint if enabled
      c.status_endpoint_token = token if token
      c.status_endpoint_path = path if path
    end
  end

  after { X402.reset_configuration! }

  def env_for(path, remote_addr: "127.0.0.1", **opts)
    Rack::MockRequest.env_for(path, method: "GET", "REMOTE_ADDR" => remote_addr, **opts)
  end

  describe "when not enabled" do
    it "passes through to the host app" do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.server_wif = test_wif
        c.gateways = [mock_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
      end

      status, _headers, body = app.call(env_for("/_x402/status"))
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "when enabled, request from localhost" do
    before { configure_with }

    it "renders HTML by default" do
      status, headers, body = app.call(env_for("/_x402/status"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to start_with("text/html")
      html = body.first
      expect(html).to include(test_pubkey_hex)
      expect(html).to include(test_address)
      expect(html).to include("Identity address")
      expect(html).to include("Not the per-payment receive address")
      expect(html).to include("x402-rack v#{X402::VERSION}")
    end

    it "renders JSON when ?format=json" do
      status, headers, body = app.call(env_for("/_x402/status?format=json"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
      data = JSON.parse(body.first)
      expect(data["x402_rack_version"]).to eq(X402::VERSION)
      expect(data["identity"]["public_key"]).to eq(test_pubkey_hex)
      expect(data["identity"]["address"]).to eq(test_address)
      expect(data["identity"]["address_note"]).to include("Not the per-payment")
    end

    it "renders JSON when Accept: application/json" do
      env = env_for("/_x402/status", "HTTP_ACCEPT" => "application/json")
      status, headers, _body = app.call(env)
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
    end

    it "accepts ::1 IPv6 localhost" do
      status, _headers, _body = app.call(env_for("/_x402/status", remote_addr: "::1"))
      expect(status).to eq(200)
    end
  end

  describe "when enabled, request from non-localhost" do
    context "with no token configured" do
      before { configure_with }

      it "returns 403" do
        status, _headers, body = app.call(env_for("/_x402/status", remote_addr: "1.2.3.4"))
        expect(status).to eq(403)
        expect(JSON.parse(body.first)).to eq("error" => "forbidden")
      end
    end

    context "with a token configured" do
      before { configure_with(token: "secret-token") }

      it "returns 200 with valid bearer token" do
        env = env_for("/_x402/status",
                      remote_addr: "1.2.3.4",
                      "HTTP_AUTHORIZATION" => "Bearer secret-token")
        status, _headers, _body = app.call(env)
        expect(status).to eq(200)
      end

      it "returns 403 with invalid bearer token" do
        env = env_for("/_x402/status",
                      remote_addr: "1.2.3.4",
                      "HTTP_AUTHORIZATION" => "Bearer wrong")
        status, _headers, _body = app.call(env)
        expect(status).to eq(403)
      end

      it "returns 403 without an Authorization header" do
        status, _headers, _body = app.call(env_for("/_x402/status", remote_addr: "1.2.3.4"))
        expect(status).to eq(403)
      end

      it "still allows localhost without a token" do
        status, _headers, _body = app.call(env_for("/_x402/status"))
        expect(status).to eq(200)
      end
    end
  end

  describe "configurable path" do
    before { configure_with(path: "/admin/x402") }

    it "serves at the configured path" do
      status, _headers, _body = app.call(env_for("/admin/x402"))
      expect(status).to eq(200)
    end

    it "passes through the default path to the host app" do
      status, _headers, body = app.call(env_for("/_x402/status"))
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "without server_wif" do
    before do
      X402.reset_configuration!
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.gateways = [mock_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
        c.enable_status_endpoint
      end
    end

    it "renders gracefully with placeholders" do
      status, _headers, body = app.call(env_for("/_x402/status"))
      expect(status).to eq(200)
      expect(body.first).to include("(not configured)")
      expect(body.first).to include("server_wif is not configured")
    end
  end

  describe "isolation from gateway logic" do
    before { configure_with }

    it "does not invoke gateway settlement when hitting the status path" do
      expect(mock_gateway).not_to receive(:settle!)
      expect(mock_gateway).not_to receive(:challenge_headers)
      app.call(env_for("/_x402/status"))
    end
  end
end
