# frozen_string_literal: true

RSpec.describe X402::Configuration do
  subject(:config) { described_class.new }

  # Minimal gateway test double implementing the required interface
  let(:mock_gateway) do
    Class.new do
      def challenge_headers(_rack_request, _route)
        { "X402-Challenge" => "test" }
      end

      def proof_header_names
        ["X402-Proof"]
      end

      def settle!(_header_name, _proof_payload, _rack_request, _route)
        X402::SettlementResult.new
      end
    end.new
  end

  let(:another_gateway) do
    Class.new do
      def challenge_headers(_rack_request, _route)
        { "Payment-Required" => "test" }
      end

      def proof_header_names
        ["Payment-Signature"]
      end

      def settle!(_header_name, _proof_payload, _rack_request, _route)
        X402::SettlementResult.new
      end
    end.new
  end

  def valid_config(config)
    config.domain = "example.com"
    config.payee_locking_script_hex = "76a914..."
    config.gateways = [mock_gateway]
    config.protect(method: "GET", path: "/", amount_sats: 1)
  end

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
      config.gateways = [mock_gateway]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /domain/)
    end

    it "raises when payee_locking_script_hex is missing" do
      config.domain = "example.com"
      config.gateways = [mock_gateway]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /payee_locking_script_hex/)
    end

    it "raises when no gateways are configured" do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /gateway/)
    end

    it "raises when gateway is missing #challenge_headers" do
      bad_gw = Object.new
      def bad_gw.proof_header_names = []
      def bad_gw.settle!(*); end

      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.gateways = [bad_gw]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /challenge_headers/)
    end

    it "raises when gateway is missing #proof_header_names" do
      bad_gw = Object.new
      def bad_gw.challenge_headers(*) = {}
      def bad_gw.settle!(*); end

      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.gateways = [bad_gw]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /proof_header_names/)
    end

    it "raises when gateway is missing #settle!" do
      bad_gw = Object.new
      def bad_gw.challenge_headers(*) = {}
      def bad_gw.proof_header_names = []

      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.gateways = [bad_gw]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /settle!/)
    end

    it "raises when two gateways claim the same proof header" do
      dup_gw = Class.new do
        def challenge_headers(*) = {}
        def proof_header_names = ["X402-Proof"]
        def settle!(*); end
      end.new

      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.gateways = [mock_gateway, dup_gw]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /duplicate proof header/)
    end

    it "raises when no routes are protected" do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.gateways = [mock_gateway]
      expect { config.validate! }.to raise_error(X402::ConfigurationError, /route/)
    end

    it "succeeds with valid configuration" do
      valid_config(config)
      expect { config.validate! }.not_to raise_error
    end

    it "succeeds with multiple gateways with distinct proof headers" do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.gateways = [mock_gateway, another_gateway]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.not_to raise_error
    end
  end
end
