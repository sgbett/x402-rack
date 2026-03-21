# frozen_string_literal: true

RSpec.describe X402::Configuration do
  subject(:config) { described_class.new }

  describe "#protect" do
    it "adds a route" do
      config.protect(method: "GET", path: "/api", amount_sats: 100)
      expect(config.routes.size).to eq(1)
      expect(config.routes.first.amount_sats).to eq(100)
    end

    it "normalises method to uppercase" do
      config.protect(method: "get", path: "/api", amount_sats: 100)
      expect(config.routes.first.http_method).to eq("GET")
    end
  end

  describe "#find_route" do
    before do
      config.protect(method: "GET", path: "/exact", amount_sats: 50)
      config.protect(method: "*", path: %r{^/api/}, amount_sats: 200)
    end

    it "matches exact string path" do
      route = config.find_route("GET", "/exact")
      expect(route.amount_sats).to eq(50)
    end

    it "returns nil for non-matching path" do
      expect(config.find_route("GET", "/other")).to be_nil
    end

    it "returns nil for non-matching method" do
      expect(config.find_route("POST", "/exact")).to be_nil
    end

    it "matches regexp path with wildcard method" do
      route = config.find_route("POST", "/api/data")
      expect(route.amount_sats).to eq(200)
    end
  end

  describe "#validate!" do
    it "raises when domain is missing" do
      config.payee_locking_script_hex = "76a914..."
      config.nonce_provider = -> {}
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /domain/)
    end

    it "raises when payee_locking_script_hex is missing" do
      config.domain = "example.com"
      config.nonce_provider = -> {}
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /payee_locking_script_hex/)
    end

    it "raises when nonce_provider is not callable" do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /nonce_provider/)
    end

    it "raises when no routes are protected" do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.nonce_provider = -> {}
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /route/)
    end

    it "succeeds with valid configuration" do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.nonce_provider = -> {}
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.not_to raise_error
    end
  end
end
