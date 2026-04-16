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

    it "stores arc_wait_for when provided" do
      config.protect(method: "GET", path: "/api", amount_sats: 100, arc_wait_for: "SEEN_ON_NETWORK")
      expect(config.routes.first.arc_wait_for).to eq("SEEN_ON_NETWORK")
    end

    it "defaults arc_wait_for to nil" do
      config.protect(method: "GET", path: "/api", amount_sats: 100)
      expect(config.routes.first.arc_wait_for).to be_nil
    end

    it "accepts a callable for amount_sats" do
      counter = 0
      callable = lambda do
        counter += 1
        counter * 100
      end
      config.protect(method: "GET", path: "/api", amount_sats: callable)
      route = config.routes.first
      expect(route.resolve_amount_sats).to eq(100)
      expect(route.resolve_amount_sats).to eq(200)
    end

    it "resolves static amount_sats via resolve_amount_sats" do
      config.protect(method: "GET", path: "/api", amount_sats: 500)
      expect(config.routes.first.resolve_amount_sats).to eq(500)
    end

    it "accepts amount_usd when exchange_rate_provider is configured" do
      provider = Object.new
      provider.define_singleton_method(:sats_for) { |_currency, _amount| 250 }
      config.exchange_rate_provider = provider
      config.protect(method: "GET", path: "/api", amount_usd: 0.25)

      expect(config.routes.first.resolve_amount_sats).to eq(250)
    end

    it "raises when amount_usd used without exchange_rate_provider" do
      expect do
        config.protect(method: "GET", path: "/api", amount_usd: 0.25)
      end.to raise_error(X402::ConfigurationError, /exchange_rate_provider/)
    end

    it "raises when both amount_sats and amount_usd provided" do
      expect do
        config.protect(method: "GET", path: "/api", amount_sats: 100, amount_usd: 0.25)
      end.to raise_error(X402::ConfigurationError, /mutually exclusive/)
    end

    it "raises when neither amount_sats nor amount_usd provided" do
      expect do
        config.protect(method: "GET", path: "/api")
      end.to raise_error(X402::ConfigurationError, /amount_sats.*amount_usd/)
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

    context "network" do
      around do |example|
        original = ENV.fetch("BSV_NETWORK", nil)
        ENV.delete("BSV_NETWORK")
        example.run
        ENV["BSV_NETWORK"] = original if original
      end

      it "defaults to bsv:mainnet" do
        valid_config(config)
        config.validate!
        expect(config.network).to eq("bsv:mainnet")
      end

      it "accepts an explicit network override" do
        valid_config(config)
        config.network = "bsv:testnet"
        config.validate!
        expect(config.network).to eq("bsv:testnet")
      end

      it "respects BSV_NETWORK env var when network is not explicitly set" do
        ENV["BSV_NETWORK"] = "bsv:testnet"
        valid_config(config)
        config.validate!
        expect(config.network).to eq("bsv:testnet")
      end

      it "explicit config.network wins over BSV_NETWORK env var" do
        ENV["BSV_NETWORK"] = "bsv:testnet"
        valid_config(config)
        config.network = "bsv:mainnet"
        config.validate!
        expect(config.network).to eq("bsv:mainnet")
      end

      it "raises on invalid network" do
        valid_config(config)
        config.network = "bsv:bogus"
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /invalid network.*bsv:bogus.*bsv:mainnet, bsv:testnet/
        )
      end

      it "raises on invalid BSV_NETWORK env var" do
        ENV["BSV_NETWORK"] = "ethereum"
        valid_config(config)
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /invalid network.*ethereum/
        )
      end

      it "treats blank BSV_NETWORK as unset (falls back to default)" do
        ENV["BSV_NETWORK"] = ""
        valid_config(config)
        config.validate!
        expect(config.network).to eq("bsv:mainnet")
      end
    end

    it "raises when neither wallet, server_wif, operator_wallet_url nor payee_locking_script_hex is set" do
      config.domain = "example.com"
      config.gateways = [mock_gateway]
      config.protect(method: "GET", path: "/", amount_sats: 1)
      expect { config.validate! }.to raise_error(X402::ConfigurationError,
                                                 /wallet, server_wif, operator_wallet_url, or payee_locking_script_hex/)
    end

    it "succeeds with server_wif instead of payee_locking_script_hex" do
      config.domain = "example.com"
      config.server_wif = "L1server"
      config.gateways = [mock_gateway]
      config.protect(method: "GET", path: "/", amount_sats: 1)

      expect { config.validate! }.not_to raise_error
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

    it "records a BRC121Gateway spec" do
      config.enable :brc121_gateway
      expect(config.gateway_specs.first).to eq(["X402::BSV::BRC121Gateway", {}])
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

    it "falls back to ARC.default when arc_url is nil" do
      arc_default = instance_double("BSV::Network::ARC")
      allow(BSV::Network::ARC).to receive(:default)
        .with(testnet: false)
        .and_return(arc_default)

      expect(config.shared_arc_client).to eq(arc_default)
    end

    it "falls back to ARC.default with testnet when network is bsv:testnet" do
      arc_default = instance_double("BSV::Network::ARC")
      config.network = "bsv:testnet"
      allow(BSV::Network::ARC).to receive(:default)
        .with(testnet: true)
        .and_return(arc_default)

      expect(config.shared_arc_client).to eq(arc_default)
    end

    it "falls back to ARC.default when arc_url is empty string" do
      arc_default = instance_double("BSV::Network::ARC")
      config.arc_url = ""
      allow(BSV::Network::ARC).to receive(:default)
        .with(testnet: false)
        .and_return(arc_default)

      expect(config.shared_arc_client).to eq(arc_default)
    end
  end

  describe "#arc_available?" do
    it "returns true even without arc_url or arc_client" do
      expect(config.send(:arc_available?)).to be true
    end

    it "returns true when arc_url is set" do
      config.arc_url = "https://arc.example.com"
      expect(config.send(:arc_available?)).to be true
    end

    it "returns true when arc_client is injected" do
      config.arc_client = instance_double("BSV::Network::ARC")
      expect(config.send(:arc_available?)).to be true
    end
  end

  describe "gateway construction (build phase)" do
    let(:arc_double) { instance_double("BSV::Network::ARC") }
    let(:nonce_provider) { ->(_req, **) { { txid: "abc", vout: 0, satoshis: 100 } } }

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
      let(:brc105_wallet) { double("wallet", internalize_action: { accepted: true }) }

      before { config.wallet = brc105_wallet }

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

      it "builds with per-gateway wallet override" do
        alt_wallet = double("alt_wallet", internalize_action: { accepted: true })
        config.enable :brc105_gateway, key_deriver: key_deriver, wallet: alt_wallet
        config.validate!

        gw = config.gateways.first
        expect(gw).to be_a(X402::BSV::BRC105Gateway)
        expect(gw.instance_variable_get(:@wallet)).to eq(alt_wallet)
      end

      it "defaults prefix_store to PrefixStore::Memory" do
        config.enable :brc105_gateway, key_deriver: key_deriver
        config.validate!

        # The gateway was built — if prefix_store was nil, the constructor would fail
        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end

      it "raises when no key source is provided" do
        config.wallet = nil
        config.payee_locking_script_hex = "76a914..."
        config.enable :brc105_gateway
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /brc105_gateway requires one of/
        )
      end

      it "raises when no wallet is provided" do
        config.wallet = nil
        config.payee_locking_script_hex = "76a914..."
        config.enable :brc105_gateway, key_deriver: key_deriver
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /brc105_gateway requires wallet/
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

      it "injects shared_arc_client when none is provided explicitly" do
        config.enable :brc105_gateway, key_deriver: key_deriver
        config.validate!

        gw = config.gateways.first
        expect(gw.instance_variable_get(:@arc_client)).to eq(arc_double)
      end

      it "allows per-gateway arc_client override" do
        custom_arc = instance_double("BSV::Network::ARC")
        config.enable :brc105_gateway, key_deriver: key_deriver, arc_client: custom_arc
        config.validate!

        gw = config.gateways.first
        expect(gw.instance_variable_get(:@arc_client)).to eq(custom_arc)
      end

      it "accepts arc_client in BRC105_GATEWAY_KNOWN_OPTS" do
        custom_arc = instance_double("BSV::Network::ARC")
        config.enable :brc105_gateway, key_deriver: key_deriver, arc_client: custom_arc
        expect { config.validate! }.not_to raise_error
      end
    end

    context "BRC121Gateway" do
      let(:wallet) do
        double("wallet", internalize_action: { accepted: true }, get_public_key: { public_key: "02#{"ab" * 32}" })
      end

      it "builds with top-level config.wallet" do
        config.wallet = wallet
        config.enable :brc121_gateway
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC121Gateway)
      end

      it "builds with per-gateway wallet override" do
        alt_wallet = double("alt_wallet", internalize_action: { accepted: true },
                                          get_public_key: { public_key: "03#{"cd" * 32}" })
        config.wallet = wallet
        config.enable :brc121_gateway, wallet: alt_wallet
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC121Gateway)
      end

      it "accepts an explicit txid_store" do
        custom_store = X402::BSV::TxidStore::Memory.new(ttl: 120)
        config.wallet = wallet
        config.enable :brc121_gateway, txid_store: custom_store
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC121Gateway)
      end

      it "raises when no wallet is provided" do
        config.enable :brc121_gateway
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /brc121_gateway requires wallet/
        )
      end

      it "raises on unknown options" do
        config.wallet = wallet
        config.enable :brc121_gateway, bad_opt: true
        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /brc121_gateway: unknown option.*:bad_opt/
        )
      end

      it "injects shared_arc_client when none is provided explicitly" do
        config.wallet = wallet
        config.enable :brc121_gateway
        config.validate!

        gw = config.gateways.first
        expect(gw.instance_variable_get(:@arc_client)).to eq(arc_double)
      end

      it "allows per-gateway arc_client override" do
        custom_arc = instance_double("BSV::Network::ARC")
        config.wallet = wallet
        config.enable :brc121_gateway, arc_client: custom_arc
        config.validate!

        gw = config.gateways.first
        expect(gw.instance_variable_get(:@arc_client)).to eq(custom_arc)
      end

      it "accepts arc_client in BRC121_GATEWAY_KNOWN_OPTS" do
        custom_arc = instance_double("BSV::Network::ARC")
        config.wallet = wallet
        config.enable :brc121_gateway, arc_client: custom_arc
        expect { config.validate! }.not_to raise_error
      end
    end

    context "auto-enable default gateways (plug-and-play)" do
      let(:wallet) do
        w = double("wallet")
        allow(w).to receive(:get_public_key).with(identity_key: true).and_return(public_key: "02#{"ab" * 32}")
        allow(w).to receive(:internalize_action).and_return(accepted: true)
        allow(w).to receive(:key_deriver).and_return(double(identity_key: "02#{"ab" * 32}"))
        w
      end

      before do
        # Override the default setup — remove payee_locking_script_hex so
        # wallet is the only payee source (pure plug-and-play path).
        config.payee_locking_script_hex = nil
      end

      it "auto-enables both PayGateway and BRC121Gateway when wallet and arc_url are set" do
        config.wallet = wallet
        config.validate!

        expect(config.gateways.map(&:class)).to contain_exactly(
          X402::BSV::PayGateway,
          X402::BSV::BRC121Gateway
        )
      end

      it "auto-enables both PayGateway and BRC121Gateway when wallet is set without arc_url (ARC.default)" do
        arc_default = instance_double("BSV::Network::ARC")
        allow(BSV::Network::ARC).to receive(:default).and_return(arc_default)

        config.wallet = wallet
        config.arc_url = nil
        config.validate!

        expect(config.gateways.map(&:class)).to contain_exactly(
          X402::BSV::PayGateway,
          X402::BSV::BRC121Gateway
        )
      end

      it "auto-enables PayGateway when arc_client is injected without arc_url" do
        config.wallet = wallet
        config.arc_url = nil
        config.arc_client = arc_double
        config.validate!

        expect(config.gateways.map(&:class)).to contain_exactly(
          X402::BSV::PayGateway,
          X402::BSV::BRC121Gateway
        )
      end

      it "does not auto-enable when an explicit enable call was made" do
        config.wallet = wallet
        config.enable :brc121_gateway
        config.validate!

        expect(config.gateways.map(&:class)).to contain_exactly(X402::BSV::BRC121Gateway)
      end

      it "does not auto-enable when gateways= array is set" do
        config.wallet = wallet
        config.gateways = [mock_gateway]
        config.validate!

        expect(config.gateways).to eq([mock_gateway])
      end

      it "does not auto-enable when only server_wif is set (backwards compat)" do
        config.server_wif = "L3server"
        config.payee_locking_script_hex = "76a914aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa88ac"
        config.gateways = [mock_gateway]
        config.validate!

        expect(config.gateways).to eq([mock_gateway])
      end

      it "passes the shared wallet to the auto-enabled BRC121Gateway" do
        config.wallet = wallet
        config.validate!

        brc121 = config.gateways.find { |g| g.is_a?(X402::BSV::BRC121Gateway) }
        expect(brc121).not_to be_nil
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

    context "server_wif shared wallet" do
      let(:private_key) { instance_double("BSV::Primitives::PrivateKey") }
      let(:key_deriver) { instance_double("BSV::Wallet::KeyDeriver") }
      let(:proto_wallet) { instance_double("BSV::Wallet::ProtoWallet", key_deriver: key_deriver) }

      before do
        config.payee_locking_script_hex = nil
        config.server_wif = "L1serverWif"

        allow(BSV::Primitives::PrivateKey).to receive(:from_wif)
          .with("L1serverWif")
          .and_return(private_key)
        allow(BSV::Wallet::ProtoWallet).to receive(:new)
          .with(private_key)
          .and_return(proto_wallet)
      end

      it "wires shared wallet into PayGateway" do
        config.enable :pay_gateway
        config.validate!

        gw = config.gateways.first
        expect(gw).to be_a(X402::BSV::PayGateway)
        expect(gw.instance_variable_get(:@wallet)).to eq(proto_wallet)
      end

      it "does not wire shared wallet into ProofGateway" do
        config.payee_locking_script_hex = "76a914..."
        config.enable :proof_gateway, nonce_provider: nonce_provider
        config.validate!

        gw = config.gateways.first
        expect(gw).to be_a(X402::BSV::ProofGateway)
        expect(gw.instance_variable_get(:@wallet)).to be_nil
      end

      it "wires shared wallet key_deriver into BRC105Gateway" do
        config.enable :brc105_gateway
        config.validate!

        gw = config.gateways.first
        expect(gw).to be_a(X402::BSV::BRC105Gateway)
      end

      it "does not require payee_locking_script_hex when server_wif is set" do
        config.enable :pay_gateway
        expect { config.validate! }.not_to raise_error
      end

      it "per-gateway wallet override takes precedence" do
        custom_wallet = instance_double("BSV::Wallet::ProtoWallet")
        config.enable :pay_gateway, wallet: custom_wallet
        config.validate!

        gw = config.gateways.first
        expect(gw.instance_variable_get(:@wallet)).to eq(custom_wallet)
      end

      it "per-gateway key_deriver override takes precedence for BRC105" do
        custom_kd = instance_double("BSV::Wallet::KeyDeriver")
        config.enable :brc105_gateway, key_deriver: custom_kd
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::BRC105Gateway)
      end

      it "memoises the shared wallet" do
        first = config.shared_wallet
        second = config.shared_wallet
        expect(first).to equal(second)
        expect(BSV::Wallet::ProtoWallet).to have_received(:new).once
      end
    end

    context "validation integration" do
      it "validates full DSL configuration successfully" do
        config.enable :pay_gateway
        config.validate!

        expect(config.gateways.size).to eq(1)
        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
      end

      it "falls back to ARC.default when DSL gateway needs shared client without arc_url" do
        arc_default = instance_double("BSV::Network::ARC")
        allow(BSV::Network::ARC).to receive(:default).and_return(arc_default)

        config.arc_url = nil
        config.enable :pay_gateway
        config.validate!

        expect(config.gateways.first).to be_a(X402::BSV::PayGateway)
        expect(config.gateways.first.arc_client).to eq(arc_default)
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
        brc105_wallet = double("wallet", internalize_action: { accepted: true })
        config.wallet = brc105_wallet
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

    context "operator_wallet_url" do
      let(:remote_wallet) { instance_double("X402::RemoteWallet") }

      before do
        config.payee_locking_script_hex = nil
        allow(X402::RemoteWallet).to receive(:new)
          .with(url: "https://wallet.example.com/api")
          .and_return(remote_wallet)
        allow(remote_wallet).to receive(:get_public_key)
          .with(identity_key: true)
          .and_return(public_key: "02#{"ab" * 32}")
        allow(remote_wallet).to receive(:internalize_action)
          .and_return(accepted: true)
      end

      it "auto-constructs a RemoteWallet as the shared wallet" do
        config.operator_wallet_url = "https://wallet.example.com/api"
        config.gateways = [mock_gateway]
        config.validate!

        expect(config.shared_wallet).to eq(remote_wallet)
        expect(X402::RemoteWallet).to have_received(:new).with(url: "https://wallet.example.com/api")
      end

      it "enables PayGateway and BRC121Gateway auto-enable" do
        config.operator_wallet_url = "https://wallet.example.com/api"
        config.validate!

        expect(config.gateways.map(&:class)).to contain_exactly(
          X402::BSV::PayGateway,
          X402::BSV::BRC121Gateway
        )
      end

      it "raises when both operator_wallet_url and wallet are set" do
        config.operator_wallet_url = "https://wallet.example.com/api"
        config.wallet = remote_wallet
        config.gateways = [mock_gateway]
        config.protect(method: "GET", path: "/", amount_sats: 1)

        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /operator_wallet_url and wallet are mutually exclusive/
        )
      end

      it "raises when both operator_wallet_url and server_wif are set" do
        config.operator_wallet_url = "https://wallet.example.com/api"
        config.server_wif = "L1serverWif"
        config.gateways = [mock_gateway]
        config.protect(method: "GET", path: "/", amount_sats: 1)

        expect { config.validate! }.to raise_error(
          X402::ConfigurationError, /operator_wallet_url and server_wif are mutually exclusive/
        )
      end

      it "accepts operator_wallet_url as a valid payee source" do
        config.operator_wallet_url = "https://wallet.example.com/api"
        config.gateways = [mock_gateway]
        config.protect(method: "GET", path: "/", amount_sats: 1)

        expect { config.validate! }.not_to raise_error
      end

      it "validates with just domain + operator_wallet_url + protect (minimal config)" do
        config.operator_wallet_url = "https://wallet.example.com/api"
        config.protect(method: "GET", path: "/api/data", amount_sats: 100)

        config.validate!

        expect(config.shared_wallet).to eq(remote_wallet)
        expect(config.gateways).not_to be_empty
      end

      it "treats empty string operator_wallet_url as unset" do
        config.operator_wallet_url = ""
        config.payee_locking_script_hex = "76a914..."
        config.gateways = [mock_gateway]
        config.protect(method: "GET", path: "/", amount_sats: 1)

        config.validate!

        expect(X402::RemoteWallet).not_to have_received(:new)
      end

      it "treats nil operator_wallet_url as unset" do
        config.operator_wallet_url = nil
        config.payee_locking_script_hex = "76a914..."
        config.gateways = [mock_gateway]
        config.protect(method: "GET", path: "/", amount_sats: 1)

        config.validate!

        expect(X402::RemoteWallet).not_to have_received(:new)
      end
    end
  end
end
