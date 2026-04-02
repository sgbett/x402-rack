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
    let(:result) { gateway.build_template(request, route.resolve_amount_sats) }
    let(:tx) { result[0] }
    let(:returned_payee_hex) { result[1] }

    it "produces a transaction with exactly 1 output (payment only, no OP_RETURN)" do
      expect(tx.outputs.size).to eq(1)
    end

    it "sets output 0 as the payment output with correct amount" do
      expect(tx.outputs[0].satoshis).to eq(100)
    end

    it "sets output 0 with the payee locking script" do
      expected_script = BSV::Script::Script.from_hex(payee_hex)
      expect(tx.outputs[0].locking_script).to eq(expected_script)
    end

    it "does not include OP_RETURN (client appends it last)" do
      expect(tx.outputs.none? { |o| o.locking_script.op_return? }).to be true
    end

    it "has no inputs" do
      expect(tx.inputs).to be_empty
    end

    it "serialises to valid binary and roundtrips" do
      binary = tx.to_binary
      restored = BSV::Transaction::Transaction.from_binary(binary)
      expect(restored.outputs.size).to eq(1)
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
      tx, returned_hex = gw.build_template(mock_request, route.resolve_amount_sats)
      expected_script = BSV::Script::Script.from_hex(payee_hex)
      expect(tx.outputs[0].locking_script).to eq(expected_script)
      expect(returned_hex).to eq(payee_hex)
    end

    it "falls back to config when constructor arg is nil" do
      X402.reset_configuration!
      X402.configuration.payee_locking_script_hex = payee_hex

      gw = described_class.new
      tx, returned_hex = gw.build_template(mock_request, route.resolve_amount_sats)
      expected_script = BSV::Script::Script.from_hex(payee_hex)
      expect(tx.outputs[0].locking_script).to eq(expected_script)
      expect(returned_hex).to eq(payee_hex)
    ensure
      X402.reset_configuration!
    end

    it "raises when neither constructor arg nor config provides a payee script" do
      X402.reset_configuration!
      gw = described_class.new
      expect { gw.build_template(mock_request, route.resolve_amount_sats) }
        .to raise_error(X402::ConfigurationError, /payee_locking_script_hex/)
    ensure
      X402.reset_configuration!
    end

    context "with wallet" do
      let(:wallet) do
        require "bsv-wallet"
        BSV::Wallet::ProtoWallet.new(BSV::Primitives::PrivateKey.generate)
      end
      let(:wallet_gw) { described_class.new(wallet: wallet) }

      it "derives a unique payee address per challenge" do
        _, hex1 = wallet_gw.build_template(mock_request, route.resolve_amount_sats)
        _, hex2 = wallet_gw.build_template(mock_request, route.resolve_amount_sats)
        expect(hex1).not_to eq(hex2)
      end

      it "returns a valid P2PKH locking script" do
        _, hex = wallet_gw.build_template(mock_request, route.resolve_amount_sats)
        expect(hex).to match(/\A76a914[0-9a-f]{40}88ac\z/)
      end

      it "uses the derived script in the payment output" do
        tx, hex = wallet_gw.build_template(mock_request, route.resolve_amount_sats)
        expected_script = BSV::Script::Script.from_hex(hex)
        expect(tx.outputs[0].locking_script).to eq(expected_script)
      end
    end
  end
end
