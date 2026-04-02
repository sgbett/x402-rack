# frozen_string_literal: true

require "rack"
require "json"

RSpec.describe "Middleware async settlement integration" do
  let(:inner_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] } }
  let(:app) { X402::Middleware.new(inner_app) }
  let(:payee_hex) { "76a914#{"aa" * 20}88ac" }

  let(:mock_worker) { instance_double("X402::SettlementWorker") }

  # Gateway that records how settle! was called, supporting both async and sync
  let(:async_aware_gateway) do
    worker = mock_worker
    settle_calls = []

    gw = Object.new

    gw.define_singleton_method(:challenge_headers) do |_request, _route|
      { "Payment-Required" => "dGVzdA" }
    end

    gw.define_singleton_method(:proof_header_names) do
      ["Payment-Signature"]
    end

    gw.define_singleton_method(:settle!) do |_header_name, _proof, _request, route|
      effective = route.arc_wait_for || "SEEN_ON_NETWORK"
      settle_calls << { arc_wait_for: effective }

      if effective.to_s == "async"
        raise X402::ConfigurationError, "no settlement_worker configured" unless worker

        worker.enqueue("fake-tx")
      end

      X402::SettlementResult.new(
        receipt_headers: { "Payment-Response" => "eyJzdWNjZXNzIjp0cnVlfQ" },
        txid: "aa" * 32,
        network: "bsv:mainnet"
      )
    end

    gw.define_singleton_method(:settle_calls) { settle_calls }
    gw
  end

  before do
    X402.reset_configuration!
  end

  after { X402.reset_configuration! }

  context "with an async route" do
    before do
      allow(mock_worker).to receive(:enqueue)

      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = payee_hex
        c.gateways = [async_aware_gateway]
        c.protect(method: "GET", path: "/async-resource", amount_sats: 100, arc_wait_for: :async)
      end
    end

    it "returns 200 and enqueues to the worker" do
      env = Rack::MockRequest.env_for("/async-resource", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "valid-proof"

      status, headers, body = app.call(env)

      expect(status).to eq(200)
      expect(body).to eq(["OK"])
      expect(headers["payment-response"]).not_to be_nil
      expect(mock_worker).to have_received(:enqueue).with("fake-tx")
    end

    it "returns 402 challenge when no proof header is present" do
      env = Rack::MockRequest.env_for("/async-resource", method: "GET")

      status, _headers, = app.call(env)

      expect(status).to eq(402)
    end
  end

  context "with a sync route" do
    before do
      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = payee_hex
        c.gateways = [async_aware_gateway]
        c.protect(method: "GET", path: "/sync-resource", amount_sats: 50)
      end
    end

    it "returns 200 without enqueuing to worker" do
      env = Rack::MockRequest.env_for("/sync-resource", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "valid-proof"

      status, headers, body = app.call(env)

      expect(status).to eq(200)
      expect(body).to eq(["OK"])
      expect(headers["payment-response"]).not_to be_nil
      # Worker should not have been called for sync route
      expect(async_aware_gateway.settle_calls.last[:arc_wait_for]).to eq("SEEN_ON_NETWORK")
    end
  end

  context "with mixed async and sync routes" do
    before do
      allow(mock_worker).to receive(:enqueue)

      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = payee_hex
        c.gateways = [async_aware_gateway]
        c.protect(method: "GET", path: "/fast", amount_sats: 10, arc_wait_for: :async)
        c.protect(method: "GET", path: "/reliable", amount_sats: 100, arc_wait_for: "MINED")
        c.protect(method: "GET", path: "/default", amount_sats: 50)
      end
    end

    it "routes /fast through async path" do
      env = Rack::MockRequest.env_for("/fast", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "proof"

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).to have_received(:enqueue)
    end

    it "routes /reliable through sync path with MINED wait_for" do
      env = Rack::MockRequest.env_for("/reliable", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "proof"

      status, = app.call(env)

      expect(status).to eq(200)
      expect(async_aware_gateway.settle_calls.last[:arc_wait_for]).to eq("MINED")
    end

    it "routes /default through sync path with gateway default" do
      env = Rack::MockRequest.env_for("/default", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "proof"

      status, = app.call(env)

      expect(status).to eq(200)
      expect(async_aware_gateway.settle_calls.last[:arc_wait_for]).to eq("SEEN_ON_NETWORK")
    end
  end

  context "async route without worker configured" do
    it "returns error when :async route but no worker" do
      no_worker_gw = Object.new

      no_worker_gw.define_singleton_method(:challenge_headers) do |_request, _route|
        { "Payment-Required" => "dGVzdA" }
      end

      no_worker_gw.define_singleton_method(:proof_header_names) do
        ["Payment-Signature"]
      end

      no_worker_gw.define_singleton_method(:settle!) do |_header_name, _proof, _request, route|
        raise X402::ConfigurationError, "no settlement_worker configured" if route.arc_wait_for.to_s == "async"

        X402::SettlementResult.new(txid: "aa" * 32)
      end

      X402.configure do |c|
        c.domain = "api.example.com"
        c.payee_locking_script_hex = payee_hex
        c.gateways = [no_worker_gw]
        c.protect(method: "GET", path: "/async-resource", amount_sats: 100, arc_wait_for: :async)
      end

      env = Rack::MockRequest.env_for("/async-resource", method: "GET")
      env["HTTP_PAYMENT_SIGNATURE"] = "proof"

      status, _, body = app.call(env)

      expect(status).to eq(400)
      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to match(/settlement_worker/)
    end
  end
end
