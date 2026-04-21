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

  # Builds a mock wallet that returns the given public key hex from
  # get_public_key. Accepts a positional hash (BRC-100 wallet style).
  def mock_wallet_returning(pubkey_hex)
    wallet = Object.new
    wallet.define_singleton_method(:get_public_key) { |_args| { public_key: pubkey_hex } }
    wallet
  end

  def configure_with(token: "secret-token", enabled: true, path: nil, wallet: nil)
    X402.reset_configuration!
    X402.configure do |c|
      c.domain = "api.example.com"
      if wallet
        c.wallet = wallet
      else
        c.server_wif = test_wif
      end
      c.gateways = [mock_gateway]
      c.protect(method: "GET", path: "/premium", amount_sats: 50)
      c.status_endpoint_token = token if token
      c.status_endpoint_path = path if path
      c.enable_status_endpoint if enabled
    end
  end

  after { X402.reset_configuration! }

  def env_for(path, **opts)
    Rack::MockRequest.env_for(path, method: "GET", **opts)
  end

  def authed_env(path, token: "secret-token", **opts)
    env_for(path, "HTTP_AUTHORIZATION" => "Bearer #{token}", **opts)
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

  describe "wallet-based identity resolution" do
    context "with server_wif (Client path)" do
      before { configure_with }

      it "displays the correct public key and address" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        html = body.first
        expect(html).to include(test_pubkey_hex)
        expect(html).to include(test_address)
        expect(html).to include("Identity address")
        expect(html).to include("Not the per-payment receive address")
      end

      it "derives the address from the public key hex" do
        expected_address = BSV::Primitives::PublicKey.from_hex(test_pubkey_hex).address
        expect(expected_address).to eq(test_address)

        status, _headers, body = app.call(authed_env("/_x402/status?format=json"))
        expect(status).to eq(200)
        data = JSON.parse(body.first)
        expect(data["identity"]["address"]).to eq(expected_address)
      end
    end

    context "with explicit wallet (Client mock)" do
      let(:wallet_mock) { mock_wallet_returning(test_pubkey_hex) }

      before { configure_with(wallet: wallet_mock) }

      it "displays the correct public key and address" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        html = body.first
        expect(html).to include(test_pubkey_hex)
        expect(html).to include(test_address)
      end
    end

    # Duck-type test — verifies the status endpoint works with any
    # wallet implementing get_public_key, not RemoteWallet's internals.
    context "with RemoteWallet mock" do
      let(:remote_wallet_mock) do
        hex = test_pubkey_hex
        wallet = Object.new
        wallet.define_singleton_method(:get_public_key) { |_args| { public_key: hex } }
        wallet
      end

      before { configure_with(wallet: remote_wallet_mock) }

      it "displays the correct public key and address" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        html = body.first
        expect(html).to include(test_pubkey_hex)
        expect(html).to include(test_address)
      end
    end

    context "with no wallet configured (payee_locking_script_hex only)" do
      before do
        X402.reset_configuration!
        X402.configure do |c|
          c.domain = "api.example.com"
          c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
          c.gateways = [mock_gateway]
          c.protect(method: "GET", path: "/premium", amount_sats: 50)
          c.status_endpoint_token = "secret-token"
          c.enable_status_endpoint
        end
      end

      it "renders gracefully with nil pubkey and address" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        expect(body.first).to include("(not configured)")
        expect(body.first).to include("No wallet configured")
      end

      it "returns nil identity fields in JSON" do
        status, _headers, body = app.call(authed_env("/_x402/status?format=json"))
        expect(status).to eq(200)
        data = JSON.parse(body.first)
        expect(data["identity"]["public_key"]).to be_nil
        expect(data["identity"]["address"]).to be_nil
        expect(data["identity"]["address_note"]).to include("No wallet configured")
      end
    end

    context "when wallet raises ConfigurationError" do
      let(:failing_wallet) do
        wallet = Object.new
        wallet.define_singleton_method(:get_public_key) do |_args|
          raise X402::ConfigurationError, "remote wallet unreachable"
        end
        wallet
      end

      before { configure_with(wallet: failing_wallet) }

      it "degrades gracefully with an error note" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        expect(body.first).to include("(not configured)")
        expect(body.first).to include("identity key could not be resolved")
      end
    end

    context "when wallet raises unexpected StandardError" do
      let(:erroring_wallet) do
        wallet = Object.new
        wallet.define_singleton_method(:get_public_key) do |_args|
          raise StandardError, "something went wrong"
        end
        wallet
      end

      before { configure_with(wallet: erroring_wallet) }

      it "degrades gracefully without crashing" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        expect(body.first).to include("(not configured)")
        expect(body.first).to include("identity key could not be resolved")
      end
    end

    context "when wallet returns malformed key" do
      let(:bad_key_wallet) { mock_wallet_returning("not-valid-hex") }

      before { configure_with(wallet: bad_key_wallet) }

      it "degrades gracefully with an error note" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        expect(body.first).to include("(not configured)")
        expect(body.first).to include("identity key could not be resolved")
      end
    end

    context "with invalid server_wif" do
      before do
        X402.reset_configuration!
        X402.configure do |c|
          c.domain = "api.example.com"
          c.server_wif = "not-a-real-wif"
          c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
          c.gateways = [mock_gateway]
          c.protect(method: "GET", path: "/premium", amount_sats: 50)
          c.status_endpoint_token = "secret-token"
          c.enable_status_endpoint
        end
      end

      it "surfaces a wallet-agnostic error rather than silently swallowing" do
        status, _headers, body = app.call(authed_env("/_x402/status"))
        expect(status).to eq(200)
        expect(body.first).to include("(not configured)")
        expect(body.first).to include("identity key could not be resolved")
      end
    end

    context "JSON format with wallet-backed identity" do
      before { configure_with }

      it "returns correct JSON structure with pubkey and address" do
        status, headers, body = app.call(authed_env("/_x402/status?format=json"))
        expect(status).to eq(200)
        expect(headers["content-type"]).to eq("application/json")
        expect(headers["cache-control"]).to eq("no-store")
        expect(headers["vary"]).to eq("Accept, Authorization")
        data = JSON.parse(body.first)
        expect(data["x402_rack_version"]).to eq(X402::VERSION)
        expect(data["identity"]["public_key"]).to eq(test_pubkey_hex)
        expect(data["identity"]["address"]).to eq(test_address)
        expect(data["identity"]["address_note"]).to include("Not the per-payment")
      end
    end
  end

  describe "rendering format" do
    before { configure_with }

    it "renders HTML by default with correct headers" do
      status, headers, body = app.call(authed_env("/_x402/status"))
      expect(status).to eq(200)
      expect(headers["content-type"]).to start_with("text/html")
      expect(headers["cache-control"]).to eq("no-store")
      expect(headers["vary"]).to eq("Accept, Authorization")
      expect(body.first).to include("x402-rack v#{X402::VERSION}")
    end

    it "renders JSON when Accept: application/json" do
      env = authed_env("/_x402/status", "HTTP_ACCEPT" => "application/json")
      status, headers, _body = app.call(env)
      expect(status).to eq(200)
      expect(headers["content-type"]).to eq("application/json")
    end
  end

  describe "auth enforcement" do
    before { configure_with(token: "secret-token") }

    it "returns 403 with no Authorization header (even from localhost)" do
      status, headers, body = app.call(env_for("/_x402/status", "REMOTE_ADDR" => "127.0.0.1"))
      expect(status).to eq(403)
      expect(headers["cache-control"]).to eq("no-store")
      expect(JSON.parse(body.first)).to eq("error" => "forbidden")
    end

    it "returns 403 with no Authorization header from non-localhost" do
      status, _headers, _body = app.call(env_for("/_x402/status", "REMOTE_ADDR" => "1.2.3.4"))
      expect(status).to eq(403)
    end

    it "returns 403 with invalid bearer token" do
      env = env_for("/_x402/status", "HTTP_AUTHORIZATION" => "Bearer wrong")
      status, _headers, _body = app.call(env)
      expect(status).to eq(403)
    end

    it "returns 403 with non-Bearer Authorization scheme" do
      env = env_for("/_x402/status", "HTTP_AUTHORIZATION" => "Basic c2VjcmV0LXRva2Vu")
      status, _headers, _body = app.call(env)
      expect(status).to eq(403)
    end

    it "is not fooled by spoofed REMOTE_ADDR=127.0.0.1" do
      # Confirms removal of the original localhost-trust bypass: an attacker
      # presenting REMOTE_ADDR=127.0.0.1 (e.g. via a misconfigured reverse proxy)
      # cannot reach the endpoint without a valid bearer token.
      status, = app.call(env_for("/_x402/status", "REMOTE_ADDR" => "127.0.0.1"))
      expect(status).to eq(403)
    end

    it "accepts valid bearer from any remote address" do
      env = authed_env("/_x402/status", "REMOTE_ADDR" => "1.2.3.4")
      status, _headers, _body = app.call(env)
      expect(status).to eq(200)
    end

    it "accepts case-insensitive Bearer scheme" do
      env = env_for("/_x402/status", "HTTP_AUTHORIZATION" => "bearer secret-token")
      status, _headers, _body = app.call(env)
      expect(status).to eq(200)
    end
  end

  describe "auto-generated token" do
    let(:captured_logs) { [] }
    let(:capturing_logger) do
      logs = captured_logs
      lgr = Object.new
      lgr.define_singleton_method(:info) { |msg| logs << msg }
      lgr.define_singleton_method(:debug) { |_| nil }
      lgr.define_singleton_method(:warn) { |_| nil }
      lgr.define_singleton_method(:error) { |_| nil }
      lgr
    end

    before do
      X402.reset_configuration!
      X402.configure do |c|
        c.logger = capturing_logger
        c.domain = "api.example.com"
        c.server_wif = test_wif
        c.gateways = [mock_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
        c.enable_status_endpoint
      end
    end

    it "generates a random token of sufficient length" do
      token = X402.configuration.status_endpoint_token
      expect(token).to be_a(String)
      expect(token.length).to be >= 32
    end

    it "logs the auto-generated token at startup" do
      token = X402.configuration.status_endpoint_token
      expect(captured_logs).to include(a_string_including("status endpoint enabled at /_x402/status"))
      expect(captured_logs).to include(a_string_including("auto-generated"))
      expect(captured_logs.any? { |m| m.include?(token) }).to be true
      expect(captured_logs).to include(a_string_including("curl -H"))
    end

    it "accepts the auto-generated token on requests" do
      token = X402.configuration.status_endpoint_token
      env = env_for("/_x402/status", "HTTP_AUTHORIZATION" => "Bearer #{token}")
      status, _headers, _body = app.call(env)
      expect(status).to eq(200)
    end

    it "does not regenerate when an explicit token has been set" do
      X402.reset_configuration!
      captured_logs.clear
      X402.configure do |c|
        c.logger = capturing_logger
        c.domain = "api.example.com"
        c.server_wif = test_wif
        c.gateways = [mock_gateway]
        c.protect(method: "GET", path: "/premium", amount_sats: 50)
        c.status_endpoint_token = "explicit-secret"
        c.enable_status_endpoint
      end
      expect(X402.configuration.status_endpoint_token).to eq("explicit-secret")
      expect(captured_logs).not_to include(a_string_including("auto-generated"))
    end
  end

  describe "configurable path" do
    before { configure_with(path: "/admin/x402") }

    it "serves at the configured path with valid bearer" do
      status, _headers, _body = app.call(authed_env("/admin/x402"))
      expect(status).to eq(200)
    end

    it "passes through the default path to the host app" do
      status, _headers, body = app.call(env_for("/_x402/status"))
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "isolation from gateway logic" do
    before { configure_with }

    it "does not invoke gateway settlement when hitting the status path" do
      expect(mock_gateway).not_to receive(:settle!)
      expect(mock_gateway).not_to receive(:challenge_headers)
      app.call(authed_env("/_x402/status"))
    end
  end
end
