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

  describe "#enable" do
    it "records a PayGateway spec" do
      config.enable :pay_gateway
      expect(config.gateway_specs.size).to eq(1)
      expect(config.gateway_specs.first).to eq(["X402::BSV::PayGateway", {}])
    end

    it "records a ProofGateway spec with options" do
      nonce_provider = double("nonce_provider")
      config.enable :proof_gateway, nonce_provider: nonce_provider
      expect(config.gateway_specs.first).to eq(["X402::BSV::ProofGateway", { nonce_provider: nonce_provider }])
    end

    it "records a BRC105Gateway spec with options" do
      config.enable :brc105_gateway, server_wif: "L3test"
      expect(config.gateway_specs.first).to eq(["X402::BSV::BRC105Gateway", { server_wif: "L3test" }])
    end

    it "raises for unknown gateway names" do
      expect { config.enable :bogus_gateway }.to raise_error(
        X402::ConfigurationError, /unknown gateway: :bogus_gateway/
      )
    end

    it "preserves order of multiple enables" do
      config.enable :pay_gateway
      config.enable :proof_gateway
      expect(config.gateway_specs.map(&:first)).to eq(
        %w[X402::BSV::PayGateway X402::BSV::ProofGateway]
      )
    end

    it "accumulates duplicate enables" do
      config.enable :proof_gateway, nonce_provider: :a
      config.enable :proof_gateway, nonce_provider: :b
      expect(config.gateway_specs.size).to eq(2)
    end
  end

  describe "#shared_arc_client" do
    let(:arc_double) { instance_double("BSV::Network::ARC") }

    it "builds ARC from url and api_key" do
      config.arc_url = "https://arc.example.com"
      config.arc_api_key = "test-key"

      allow(BSV::Network::ARC).to receive(:new)
        .with("https://arc.example.com", api_key: "test-key")
        .and_return(arc_double)

      expect(config.shared_arc_client).to eq(arc_double)
    end

    it "works with nil api_key" do
      config.arc_url = "https://arc.example.com"

      allow(BSV::Network::ARC).to receive(:new)
        .with("https://arc.example.com", api_key: nil)
        .and_return(arc_double)

      expect(config.shared_arc_client).to eq(arc_double)
    end

    it "returns injected arc_client when set" do
      config.arc_client = arc_double

      expect(config.shared_arc_client).to eq(arc_double)
    end

    it "prefers injected arc_client over arc_url" do
      config.arc_url = "https://arc.example.com"
      config.arc_client = arc_double

      expect(config.shared_arc_client).to eq(arc_double)
      expect(BSV::Network::ARC).not_to receive(:new)
    end

    it "memoises the built client" do
      config.arc_url = "https://arc.example.com"

      allow(BSV::Network::ARC).to receive(:new)
        .with("https://arc.example.com", api_key: nil)
        .and_return(arc_double)

      first_call = config.shared_arc_client
      second_call = config.shared_arc_client

      expect(first_call).to equal(second_call)
      expect(BSV::Network::ARC).to have_received(:new).once
    end

    it "raises when arc_url is missing and no injected client" do
      expect { config.shared_arc_client }.to raise_error(
        X402::ConfigurationError, /arc_url is required/
      )
    end
  end

  describe "gateway construction (build phase)" do
    let(:arc_double) { instance_double("BSV::Network::ARC") }
    let(:nonce_provider) { ->(_req, _route) { { txid: "abc", vout: 0, satoshis: 100 } } }

    before do
      config.domain = "example.com"
      config.payee_locking_script_hex = "76a914..."
      config.arc_url = "https://arc.example.com"
      config.protect(method: "GET", path: "/", amount_sats: 1)

      allow(BSV::Network::ARC).to receive(:new)
        .with("https://arc.example.com", api_key: nil)
        .and_return(arc_double)
    end

    context "PayGateway" do
      it "builds with shared arc_client and global payee_locking_script_hex" do
        config.enable :pay_gateway
        config.validate!

        gw = config.gateways.first
        expect(gw).to be_a(X402::BSV::PayGateway)
        expect(gw.arc_client).to eq(arc_double)
      end

      it "passes through optional params" do
        config.enable :pay_gateway, arc_wait_for: "MINED", arc_timeout: 30, binding_mode: :strict
        config.validate!

        gw = config.gateways.first
        expect(gw.arc_wait_for).to eq("MINED")
        expect(gw.arc_timeout).to eq(30)
        expect(gw.binding_mode).to eq(:strict)
      end

      it "uses per-gateway arc_client override" do
        custom_arc = instance_double("BSV::Network::ARC")
        config.enable :pay_gateway, arc_client: custom_arc
        config.validate!

        expect(config.gateways.first.arc_client).to eq(custom_arc)
      end

      it "raises on unknown options" do
        config.enable :pay_gateway, bogus: true
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /pay_gateway: unknown option.*:bogus/
        )
      end
    end

    context "ProofGateway" do
      it "builds with shared dependencies" do
        config.enable :proof_gateway, nonce_provider: nonce_provider
        config.validate!

        gw = config.gateways.first
        expect(gw).to be_a(X402::BSV::ProofGateway)
      end

      it "raises when nonce_provider is missing" do
        config.enable :proof_gateway
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /nonce_provider/
        )
      end

      it "expands nonce_wif to nonce_key" do
        private_key = instance_double("BSV::Primitives::PrivateKey")
        allow(BSV::Primitives::PrivateKey).to receive(:from_wif)
          .with("L3nonce")
          .and_return(private_key)

        config.enable :proof_gateway, nonce_provider: nonce_provider, nonce_wif: "L3nonce"
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::ProofGateway)
      end

      it "raises when both nonce_wif and nonce_key are provided" do
        config.enable :proof_gateway, nonce_provider: nonce_provider, nonce_wif: "L3x", nonce_key: :key
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /nonce_wif.*nonce_key.*mutually exclusive/
        )
      end

      it "raises on unknown options" do
        config.enable :proof_gateway, nonce_provider: nonce_provider, foo: 1
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /proof_gateway: unknown option.*:foo/
        )
      end
    end

    context "BRC105Gateway" do
      let(:private_key) { instance_double("BSV::Primitives::PrivateKey") }
      let(:key_deriver) { instance_double("BSV::Wallet::KeyDeriver") }

      it "builds with server_wif convenience" do
        allow(BSV::Primitives::PrivateKey).to receive(:from_wif)
          .with("L3server")
          .and_return(private_key)
        allow(BSV::Wallet::KeyDeriver).to receive(:new)
          .with(private_key)
          .and_return(key_deriver)

        config.enable :brc105_gateway, server_wif: "L3server"
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end

      it "builds with server_key convenience" do
        allow(BSV::Wallet::KeyDeriver).to receive(:new)
          .with(private_key)
          .and_return(key_deriver)

        config.enable :brc105_gateway, server_key: private_key
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end

      it "builds with explicit key_deriver" do
        config.enable :brc105_gateway, key_deriver: key_deriver
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end

      it "defaults prefix_store to PrefixStore::Memory" do
        config.enable :brc105_gateway, key_deriver: key_deriver
        config.validate!

        # The gateway was built — if prefix_store was nil, the constructor would fail
        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end

      it "raises when no key source is provided" do
        config.enable :brc105_gateway
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /brc105_gateway requires one of/
        )
      end

      it "raises when conflicting key sources are provided" do
        config.enable :brc105_gateway, server_wif: "L3x", key_deriver: key_deriver
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /mutually exclusive/
        )
      end

      it "raises on unknown options" do
        config.enable :brc105_gateway, key_deriver: key_deriver, bad_opt: true
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /brc105_gateway: unknown option.*:bad_opt/
        )
      end
    end

    context "gateways= takes precedence" do
      it "ignores gateway_specs when gateways is set before enable" do
        config.gateways = [mock_gateway]
        config.enable :pay_gateway
        config.validate!

        expect(config.gateways).to eq([mock_gateway])
      end

      it "ignores gateway_specs when gateways is set after enable" do
        config.enable :pay_gateway
        config.gateways = [mock_gateway]
        config.validate!

        expect(config.gateways).to eq([mock_gateway])
      end
    end

    context "per-gateway payee_locking_script_hex override" do
      it "uses per-gateway override for PayGateway" do
        config.enable :pay_gateway, payee_locking_script_hex: "custom_hex"
        config.validate!

        # Gateway was built without error — the override was accepted
        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
      end
    end

    context "validation integration" do
      it "validates full DSL configuration successfully" do
        config.enable :pay_gateway
        config.validate!

        expect(config.gateways.size).to eq(1)
        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
      end

      it "raises missing arc_url when DSL gateway needs shared client" do
        config.arc_url = nil
        config.enable :pay_gateway
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /arc_url is required/
        )
      end

      it "does not require arc_url when all gateways provide own arc_client" do
        custom_arc = instance_double("BSV::Network::ARC")
        config.arc_url = nil
        config.enable :pay_gateway, arc_client: custom_arc
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
      end

      it "treats empty gateways array as not set and builds from specs" do
        config.gateways = []
        config.enable :pay_gateway
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
      end

      it "raises when neither gateways nor enable used" do
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /at least one gateway/
        )
      end

      it "supports deferred construction — arc_url set after enable" do
        config.enable :pay_gateway
        config.arc_url = "https://arc.example.com"
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
      end

      it "shares the same ARC client instance across multiple gateways" do
        config.enable :pay_gateway
        config.enable :proof_gateway, nonce_provider: nonce_provider
        config.validate!

        pay_gw = config.gateways[0]
        proof_gw = config.gateways[1]
        expect(pay_gw.arc_client).to equal(proof_gw.instance_variable_get(:@arc_client))
      end

      it "allows power user to provide explicit key_deriver and prefix_store" do
        key_deriver = instance_double("BSV::Wallet::KeyDeriver")
        prefix_store = instance_double("X402::BSV::PrefixStore::Memory")
        config.enable :brc105_gateway, key_deriver: key_deriver, prefix_store: prefix_store
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end
    end

    context "full configure block integration" do
      before { X402.reset_configuration! }
      after { X402.reset_configuration! }

      it "works via X402.configure with DSL" do
        allow(BSV::Network::ARC).to receive(:new).and_return(arc_double)

        X402.configure do |c|
          c.domain = "example.com"
          c.payee_locking_script_hex = "76a914..."
          c.arc_url = "https://arc.example.com"
          c.enable :pay_gateway
          c.protect(method: "GET", path: "/", amount_sats: 100)
        end

        expect(X402.configuration.gateways.size).to eq(1)
        expect(X402.configuration.gateways.first).to be_a(X402::BSV::PayGateway)
      end
    end
  end
end
