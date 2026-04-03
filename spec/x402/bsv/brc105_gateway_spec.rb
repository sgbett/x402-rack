# frozen_string_literal: true

require "rack"
require "json"
require "base64"
require "openssl"
require "bsv-wallet"
require "x402/bsv/brc105_gateway"
require "x402/bsv/prefix_store"

RSpec.describe X402::BSV::BRC105Gateway do
  let(:identity_key) { "02#{"ab" * 32}" }
  let(:key_deriver) { double("key_deriver", identity_key: identity_key) }
  let(:prefix_store) { X402::BSV::PrefixStore::Memory.new }
  let(:arc_client) { double("arc_client") }
  let(:gateway) do
    described_class.new(key_deriver: key_deriver, prefix_store: prefix_store, arc_client: arc_client)
  end
  let(:route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 1000) }

  def mock_request(env_overrides = {})
    env = Rack::MockRequest.env_for("/premium", method: "GET")
    env.merge!(env_overrides)
    Rack::Request.new(env)
  end

  describe "#challenge_headers" do
    context "standalone mode (no BRC-103)" do
      let(:request) { mock_request }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "returns all three x-bsv-payment headers" do
        expect(headers).to include(
          "x-bsv-payment-satoshis-required",
          "x-bsv-payment-derivation-prefix",
          "x-bsv-payment-identity-key"
        )
      end

      it "sets satoshis-required to the route amount" do
        expect(headers["x-bsv-payment-satoshis-required"]).to eq("1000")
      end

      it "returns a 32-character hex derivation prefix" do
        expect(headers["x-bsv-payment-derivation-prefix"]).to match(/\A[0-9a-f]{32}\z/)
      end

      it "returns the key deriver identity key" do
        expect(headers["x-bsv-payment-identity-key"]).to eq(identity_key)
      end

      it "stores the prefix in the prefix store" do
        prefix = headers["x-bsv-payment-derivation-prefix"]
        expect(prefix_store.valid?(prefix)).to be true
      end
    end

    context "when prefix store is full" do
      let(:full_store) { X402::BSV::PrefixStore::Memory.new(max_issued: 0) }
      let(:full_gateway) do
        described_class.new(key_deriver: key_deriver, prefix_store: full_store, arc_client: arc_client)
      end

      it "raises VerificationError with 503" do
        expect { full_gateway.challenge_headers(mock_request, route) }
          .to raise_error(X402::VerificationError, /at capacity/) { |e| expect(e.status).to eq(503) }
      end
    end

    context "with BRC-103 identity key in env" do
      let(:request) { mock_request("brc103.identity_key" => "02#{"cd" * 32}") }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "returns two headers (no identity key)" do
        expect(headers.keys).to contain_exactly(
          "x-bsv-payment-satoshis-required",
          "x-bsv-payment-derivation-prefix"
        )
      end

      it "omits the identity key header" do
        expect(headers).not_to have_key("x-bsv-payment-identity-key")
      end
    end

    context "with empty string brc103.identity_key (treated as absent)" do
      let(:request) { mock_request("brc103.identity_key" => "") }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "includes the identity key header" do
        expect(headers).to include("x-bsv-payment-identity-key")
      end
    end

    context "with nil brc103.identity_key (treated as absent)" do
      let(:request) { mock_request("brc103.identity_key" => nil) }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "includes the identity key header" do
        expect(headers).to include("x-bsv-payment-identity-key")
      end
    end

    context "with invalid brc103.identity_key (not a compressed pubkey)" do
      let(:request) { mock_request("brc103.identity_key" => "anyone") }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "falls back to standalone mode" do
        expect(headers).to include("x-bsv-payment-identity-key")
      end
    end

    context "with non-hex brc103.identity_key" do
      let(:request) { mock_request("brc103.identity_key" => "not-a-pubkey") }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "falls back to standalone mode" do
        expect(headers).to include("x-bsv-payment-identity-key")
      end
    end
  end

  describe "#proof_header_names" do
    it "returns the x-bsv-payment header" do
      expect(gateway.proof_header_names).to eq(["x-bsv-payment"])
    end
  end

  describe "#settle!" do
    # Use real SDK objects for settle! tests
    let(:server_key) { BSV::Primitives::PrivateKey.generate }
    let(:real_key_deriver) { BSV::Wallet::KeyDeriver.new(server_key) }
    let(:real_gateway) do
      described_class.new(key_deriver: real_key_deriver, prefix_store: prefix_store, arc_client: arc_client)
    end

    let(:prefix) { SecureRandom.hex(16) }
    let(:suffix) { SecureRandom.hex(16) }
    let(:request) { mock_request }

    # Derive the expected payment script (same logic as the gateway)
    let(:derived_pubkey) do
      real_key_deriver.derive_public_key(
        [2, "3241645161d8"], "#{prefix} #{suffix}", "anyone", for_self: true
      )
    end
    let(:payment_script_hex) do
      h160 = derived_pubkey.hash160.unpack1("H*")
      "76a914#{h160}88ac"
    end

    # Build a minimal transaction paying to the derived address
    def build_payment_tx(amount:, script_hex:)
      transaction = BSV::Transaction::Transaction.new
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: ["ee" * 32].pack("H*"),
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: amount,
                               locking_script: BSV::Script::Script.from_hex(script_hex)
                             ))
      transaction
    end

    # Wrap a transaction in AtomicBEEF format
    def build_atomic_beef_b64(transaction)
      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(transaction)
      atomic_binary = beef.to_atomic_binary(transaction.txid)
      Base64.strict_encode64(atomic_binary)
    end

    def build_proof_payload(prefix:, suffix:, transaction:)
      JSON.generate({
                      "derivationPrefix" => prefix,
                      "derivationSuffix" => suffix,
                      "transaction" => build_atomic_beef_b64(transaction)
                    })
    end

    before do
      prefix_store.store!(prefix)
      allow(arc_client).to receive(:broadcast).and_return({ "txid" => "aa" * 32 })
    end

    context "happy path" do
      it "settles successfully and returns a SettlementResult" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(result).to be_a(X402::SettlementResult)
        expect(result.txid).to eq(transaction.txid_hex)
        expect(result.network).to eq("bsv:mainnet")
        expect(result.receipt_headers).to have_key("x-bsv-payment-result")
      end

      it "broadcasts via ARC" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(arc_client).to have_received(:broadcast)
      end
    end

    context "replay protection" do
      it "rejects a replayed prefix (400)" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /replay/) { |e| expect(e.status).to eq(400) }
      end
    end

    context "insufficient payment" do
      it "rejects underpayment (402)" do
        transaction = build_payment_tx(amount: 999, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /no output pays/) { |e| expect(e.status).to eq(402) }
      end
    end

    context "wrong derivation suffix" do
      it "rejects payment to wrong address (402)" do
        wrong_suffix = SecureRandom.hex(16)
        wrong_pubkey = real_key_deriver.derive_public_key(
          [2, "3241645161d8"], "#{prefix} #{wrong_suffix}", "anyone", for_self: true
        )
        wrong_h160 = wrong_pubkey.hash160.unpack1("H*")
        wrong_script = "76a914#{wrong_h160}88ac"

        transaction = build_payment_tx(amount: 1000, script_hex: wrong_script)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /no output pays/) { |e| expect(e.status).to eq(402) }
      end
    end

    context "malformed JSON" do
      it "raises VerificationError (400)" do
        expect { real_gateway.settle!("x-bsv-payment", "not{json", request, route) }
          .to raise_error(X402::VerificationError, /invalid payment JSON/) { |e| expect(e.status).to eq(400) }
      end
    end

    context "missing derivationSuffix" do
      it "raises VerificationError (400) for nil suffix" do
        payload = JSON.generate({ "derivationPrefix" => prefix, "transaction" => "AA==" })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /missing derivationSuffix/) { |e| expect(e.status).to eq(400) }
      end

      it "raises VerificationError (400) for empty suffix" do
        payload = JSON.generate({ "derivationPrefix" => prefix, "derivationSuffix" => "", "transaction" => "AA==" })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /invalid derivationSuffix format/) { |e| expect(e.status).to eq(400) }
      end
    end

    context "missing derivationPrefix" do
      it "raises VerificationError (400)" do
        payload = JSON.generate({ "derivationSuffix" => suffix, "transaction" => "AA==" })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /missing derivationPrefix/) { |e| expect(e.status).to eq(400) }
      end
    end

    context "ARC broadcast failure" do
      it "raises VerificationError (502)" do
        allow(arc_client).to receive(:broadcast).and_raise(StandardError, "network timeout")
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /ARC broadcast failed/) { |e| expect(e.status).to eq(502) }
      end
    end

    context "missing transaction field" do
      it "raises VerificationError (400)" do
        payload = JSON.generate({ "derivationPrefix" => prefix, "derivationSuffix" => suffix })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /missing transaction/) { |e| expect(e.status).to eq(400) }
      end
    end

    context "BRC-103 mode (real counterparty key)" do
      let(:client_key) { BSV::Primitives::PrivateKey.generate }
      let(:counterparty) { client_key.public_key.to_hex }
      let(:brc103_request) { mock_request("brc103.identity_key" => counterparty) }

      let(:brc103_derived_pubkey) do
        real_key_deriver.derive_public_key(
          [2, "3241645161d8"], "#{prefix} #{suffix}", counterparty, for_self: true
        )
      end
      let(:brc103_script_hex) do
        h160 = brc103_derived_pubkey.hash160.unpack1("H*")
        "76a914#{h160}88ac"
      end

      it "settles with a real counterparty key" do
        transaction = build_payment_tx(amount: 1000, script_hex: brc103_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, brc103_request, route)

        expect(result).to be_a(X402::SettlementResult)
        expect(result.txid).to eq(transaction.txid_hex)
      end
    end
  end
end
