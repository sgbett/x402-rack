# frozen_string_literal: true

require "rack"

RSpec.describe X402::Challenge do
  let(:nonce) do
    {
      txid: "a" * 64,
      vout: 0,
      satoshis: 1000,
      locking_script_hex: "76a914#{"bb" * 20}88ac"
    }
  end

  let(:config) do
    c = X402::Configuration.new
    c.domain = "api.example.com"
    c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
    c.nonce_provider = ->(_req) { nonce }
    c.protect(method: "GET", path: "/v1/premium", amount_sats: 50)
    c
  end

  let(:route) { config.routes.first }

  let(:rack_request) do
    env = Rack::MockRequest.env_for("/v1/premium", method: "GET")
    Rack::Request.new(env)
  end

  describe ".build" do
    subject(:challenge) { described_class.build(rack_request, route: route, config: config) }

    it "sets version to 1" do
      expect(challenge.version).to eq(1)
    end

    it "sets scheme to bsv-tx-v1" do
      expect(challenge.scheme).to eq("bsv-tx-v1")
    end

    it "captures domain from config" do
      expect(challenge.domain).to eq("api.example.com")
    end

    it "captures request method and path" do
      expect(challenge.method).to eq("GET")
      expect(challenge.path).to eq("/v1/premium")
    end

    it "includes nonce UTXO details" do
      expect(challenge.nonce_txid).to eq("a" * 64)
      expect(challenge.nonce_vout).to eq(0)
    end

    it "sets expiration in the future" do
      expect(challenge.expires_at).to be > Time.now.to_i
    end
  end

  describe "#to_h / #to_canonical_json / #sha256_hex" do
    subject(:challenge) { described_class.build(rack_request, route: route, config: config) }

    it "roundtrips through to_h" do
      hash = challenge.to_h
      expect(hash[:version]).to eq(1)
      expect(hash[:amount_sats]).to eq(50)
    end

    it "produces deterministic canonical JSON" do
      json1 = challenge.to_canonical_json
      json2 = challenge.to_canonical_json
      expect(json1).to eq(json2)
    end

    it "computes a SHA-256 hex digest of canonical JSON" do
      hex = challenge.sha256_hex
      expect(hex).to match(/\A[0-9a-f]{64}\z/)
    end
  end

  describe "#to_header / .from_header roundtrip" do
    subject(:challenge) { described_class.build(rack_request, route: route, config: config) }

    it "roundtrips through header encoding" do
      header = challenge.to_header
      restored = described_class.from_header(header)
      expect(restored.version).to eq(challenge.version)
      expect(restored.nonce_txid).to eq(challenge.nonce_txid)
      expect(restored.amount_sats).to eq(challenge.amount_sats)
    end
  end
end
