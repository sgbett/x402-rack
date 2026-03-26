# frozen_string_literal: true

require "rack"
require "x402/bsv/gateway"

RSpec.describe X402::BSV::Gateway do
  let(:payee_hex) { "76a914#{"aa" * 20}88ac" }
  let(:gateway) { described_class.new(payee_locking_script_hex: payee_hex) }
  let(:route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 100) }

  def mock_request(method: "GET", path: "/premium", query: "")
    url = query.empty? ? path : "#{path}?#{query}"
    env = Rack::MockRequest.env_for(url, method: method)
    Rack::Request.new(env)
  end

  describe "#build_template" do
    let(:request) { mock_request }
    let(:tx) { gateway.build_template(request, route) }

    it "produces a transaction with exactly 2 outputs" do
      expect(tx.outputs.size).to eq(2)
    end

    it "sets output 0 as the payment output with correct amount" do
      expect(tx.outputs[0].satoshis).to eq(100)
    end

    it "sets output 0 with the payee locking script" do
      expected_script = BSV::Script::Script.from_hex(payee_hex)
      expect(tx.outputs[0].locking_script).to eq(expected_script)
    end

    it "sets output 1 as an OP_RETURN" do
      expect(tx.outputs[1].locking_script.op_return?).to be true
    end

    it "sets output 1 with 0 satoshis" do
      expect(tx.outputs[1].satoshis).to eq(0)
    end

    it "has no inputs" do
      expect(tx.inputs).to be_empty
    end

    it "serialises to valid binary and roundtrips" do
      binary = tx.to_binary
      restored = BSV::Transaction::Transaction.from_binary(binary)
      expect(restored.outputs.size).to eq(2)
      expect(restored.outputs[0].satoshis).to eq(100)
    end
  end

  describe "#request_binding_hash" do
    it "is deterministic for the same request" do
      req = mock_request
      hash1 = gateway.request_binding_hash(req)
      hash2 = gateway.request_binding_hash(req)
      expect(hash1).to eq(hash2)
    end

    it "differs when method changes" do
      get_hash = gateway.request_binding_hash(mock_request(method: "GET"))
      post_hash = gateway.request_binding_hash(mock_request(method: "POST"))
      expect(get_hash).not_to eq(post_hash)
    end

    it "differs when path changes" do
      hash1 = gateway.request_binding_hash(mock_request(path: "/a"))
      hash2 = gateway.request_binding_hash(mock_request(path: "/b"))
      expect(hash1).not_to eq(hash2)
    end

    it "differs when query changes" do
      hash1 = gateway.request_binding_hash(mock_request(query: "a=1"))
      hash2 = gateway.request_binding_hash(mock_request(query: "a=2"))
      expect(hash1).not_to eq(hash2)
    end

    it "returns a 32-byte binary string" do
      hash = gateway.request_binding_hash(mock_request)
      expect(hash.bytesize).to eq(32)
      expect(hash.encoding).to eq(Encoding::BINARY)
    end
  end

  describe "payee_locking_script_hex resolution" do
    it "uses the constructor arg when provided" do
      gw = described_class.new(payee_locking_script_hex: payee_hex)
      tx = gw.build_template(mock_request, route)
      expected_script = BSV::Script::Script.from_hex(payee_hex)
      expect(tx.outputs[0].locking_script).to eq(expected_script)
    end

    it "falls back to config when constructor arg is nil" do
      X402.reset_configuration!
      X402.configuration.payee_locking_script_hex = payee_hex

      gw = described_class.new
      tx = gw.build_template(mock_request, route)
      expected_script = BSV::Script::Script.from_hex(payee_hex)
      expect(tx.outputs[0].locking_script).to eq(expected_script)
    ensure
      X402.reset_configuration!
    end

    it "raises when neither constructor arg nor config provides a payee script" do
      X402.reset_configuration!
      gw = described_class.new
      expect { gw.build_template(mock_request, route) }
        .to raise_error(X402::ConfigurationError, /payee_locking_script_hex/)
    ensure
      X402.reset_configuration!
    end
  end
end
