# frozen_string_literal: true

require "rack"
require "json"
require "x402/payment_observer"

RSpec.describe X402::PaymentObserver do
  let(:inner_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] } }
  let(:mock_worker) { instance_double("X402::SettlementWorker") }
  let(:payee_hex) { "76a914#{"aa" * 20}88ac" }

  let(:app) do
    described_class.new(inner_app, worker: mock_worker,
                                   payee_locking_script_hex: payee_hex)
  end

  # Build a minimal valid tx that pays the configured payee
  def build_proof(locking_script_hex: payee_hex)
    tx = BSV::Transaction::Transaction.new
    tx.add_output(BSV::Transaction::TransactionOutput.new(
                    satoshis: 100,
                    locking_script: BSV::Script::Script.from_hex(locking_script_hex)
                  ))
    rawtx_hex = tx.to_binary.unpack1("H*")
    payload = { "payload" => { "rawtx" => rawtx_hex, "txid" => "bb" * 32 } }
    Base64.strict_encode64(JSON.generate(payload))
  end

  before { allow(mock_worker).to receive(:enqueue) }

  describe "payment detection" do
    it "enqueues tx when Payment-Signature header is present and pays us" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = build_proof

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).to have_received(:enqueue).once
    end

    it "passes through when no payment header is present" do
      env = Rack::MockRequest.env_for("/anything", method: "GET")

      status, _, body = app.call(env)

      expect(status).to eq(200)
      expect(body).to eq(["OK"])
      expect(mock_worker).not_to have_received(:enqueue)
    end

    it "passes through when payment header is empty" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = ""

      app.call(env)

      expect(mock_worker).not_to have_received(:enqueue)
    end
  end

  describe "payee filter" do
    it "rejects tx that does not pay our address" do
      other_payee = "76a914#{"bb" * 20}88ac"
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = build_proof(locking_script_hex: other_payee)

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).not_to have_received(:enqueue)
    end

    it "accepts tx with multiple outputs where one pays us" do
      tx = BSV::Transaction::Transaction.new
      # Output 0: someone else
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: 50,
                      locking_script: BSV::Script::Script.from_hex("76a914#{"cc" * 20}88ac")
                    ))
      # Output 1: pays us
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: 100,
                      locking_script: BSV::Script::Script.from_hex(payee_hex)
                    ))
      rawtx_hex = tx.to_binary.unpack1("H*")
      payload = { "payload" => { "rawtx" => rawtx_hex, "txid" => "cc" * 32 } }
      proof = Base64.strict_encode64(JSON.generate(payload))

      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = proof

      app.call(env)

      expect(mock_worker).to have_received(:enqueue).once
    end
  end

  describe "invalid payment handling" do
    it "silently ignores malformed base64" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = "not-valid-base64!!!"

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).not_to have_received(:enqueue)
    end

    it "silently ignores malformed JSON" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = Base64.strict_encode64("not json")

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).not_to have_received(:enqueue)
    end

    it "silently ignores payload without rawtx" do
      payload = { "payload" => { "something" => "else" } }
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = Base64.strict_encode64(JSON.generate(payload))

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).not_to have_received(:enqueue)
    end

    it "silently ignores invalid transaction binary" do
      payload = { "payload" => { "rawtx" => "deadbeef" } }
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = Base64.strict_encode64(JSON.generate(payload))

      status, = app.call(env)

      expect(status).to eq(200)
      expect(mock_worker).not_to have_received(:enqueue)
    end

    it "always passes request through even on invalid payment" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = "garbage"

      status, _, body = app.call(env)

      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "custom proof headers" do
    let(:app) do
      described_class.new(inner_app, worker: mock_worker,
                                     payee_locking_script_hex: payee_hex,
                                     proof_headers: %w[X-BSV-Payment])
    end

    it "detects payment on custom header" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_X_BSV_PAYMENT"] = build_proof

      app.call(env)

      expect(mock_worker).to have_received(:enqueue).once
    end

    it "ignores default header when custom headers configured" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = build_proof

      app.call(env)

      expect(mock_worker).not_to have_received(:enqueue)
    end
  end

  describe "on_payment callback" do
    let(:received) { [] }
    let(:callback) { ->(tx) { received << tx } }
    let(:app) do
      described_class.new(inner_app, worker: mock_worker,
                                     payee_locking_script_hex: payee_hex,
                                     on_payment: callback)
    end

    it "invokes callback with tx binary after enqueue" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = build_proof

      app.call(env)

      expect(received.size).to eq(1)
      expect(received.first).to be_a(String)
    end

    it "does not invoke callback when no payment detected" do
      env = Rack::MockRequest.env_for("/anything", method: "GET")

      app.call(env)

      expect(received).to be_empty
    end

    it "does not invoke callback when tx does not pay us" do
      other_payee = "76a914#{"bb" * 20}88ac"
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = build_proof(locking_script_hex: other_payee)

      app.call(env)

      expect(received).to be_empty
    end
  end

  describe "multiple headers" do
    let(:app) do
      described_class.new(inner_app, worker: mock_worker,
                                     payee_locking_script_hex: payee_hex,
                                     proof_headers: %w[Payment-Signature X-BSV-Payment])
    end

    it "uses the first matching header" do
      env = Rack::MockRequest.env_for("/anything", method: "POST")
      env["HTTP_PAYMENT_SIGNATURE"] = build_proof
      env["HTTP_X_BSV_PAYMENT"] = build_proof

      app.call(env)

      expect(mock_worker).to have_received(:enqueue).once
    end
  end
end
