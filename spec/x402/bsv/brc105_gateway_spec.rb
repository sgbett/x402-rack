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
  let(:wallet) { double("wallet") }
  let(:gateway) do
    described_class.new(key_deriver: key_deriver, prefix_store: prefix_store, wallet: wallet)
  end
  let(:route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 1000) }

  def mock_request(env_overrides = {})
    env = Rack::MockRequest.env_for("/premium", method: "GET")
    env.merge!(env_overrides)
    Rack::Request.new(env)
  end

  # ---------------------------------------------------------------------------
  # §5.2 Payment Headers / §6.2 Server's 402 Response
  # ---------------------------------------------------------------------------
  describe "§5.2/§6.2 — 402 challenge headers" do
    context "standalone mode (no BRC-103)" do
      let(:request) { mock_request }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "includes all four required x-bsv-payment headers" do
        expect(headers).to include(
          "x-bsv-payment-version",
          "x-bsv-payment-satoshis-required",
          "x-bsv-payment-derivation-prefix",
          "x-bsv-payment-identity-key"
        )
      end

      # §5.2: "The current supported version is 1.0."
      it "sets x-bsv-payment-version to '1.0'" do
        expect(headers["x-bsv-payment-version"]).to eq("1.0")
      end

      # §5.2: "Integer number of satoshis needed for this request."
      it "sets x-bsv-payment-satoshis-required to the route amount" do
        expect(headers["x-bsv-payment-satoshis-required"]).to eq("1000")
      end

      # §5.2: "Payment-level nonce for deriving the payment output script."
      it "returns a 32-character hex derivation prefix" do
        expect(headers["x-bsv-payment-derivation-prefix"]).to match(/\A[0-9a-f]{32}\z/)
      end

      # Standalone mode: identity key must be present for clients without BRC-103
      it "includes the server identity key" do
        expect(headers["x-bsv-payment-identity-key"]).to eq(identity_key)
      end
    end

    # §4: BRC-105 sits on top of BRC-103/104. When mutual auth is present,
    # the identity key is already known — no need to repeat it in headers.
    context "with BRC-103 identity key in env" do
      let(:request) { mock_request("brc103.identity_key" => "02#{"cd" * 32}") }
      let(:headers) { gateway.challenge_headers(request, route) }

      it "omits the identity key header" do
        expect(headers).not_to have_key("x-bsv-payment-identity-key")
      end

      it "still includes version, satoshis-required, and derivation-prefix" do
        expect(headers.keys).to contain_exactly(
          "x-bsv-payment-version",
          "x-bsv-payment-satoshis-required",
          "x-bsv-payment-derivation-prefix"
        )
      end
    end

    context "BRC-103 identity key edge cases" do
      it "treats empty string as absent (includes identity key)" do
        headers = gateway.challenge_headers(mock_request("brc103.identity_key" => ""), route)
        expect(headers).to include("x-bsv-payment-identity-key")
      end

      it "treats nil as absent (includes identity key)" do
        headers = gateway.challenge_headers(mock_request("brc103.identity_key" => nil), route)
        expect(headers).to include("x-bsv-payment-identity-key")
      end

      it "treats invalid pubkey as absent (includes identity key)" do
        headers = gateway.challenge_headers(mock_request("brc103.identity_key" => "anyone"), route)
        expect(headers).to include("x-bsv-payment-identity-key")
      end

      it "treats non-hex string as absent (includes identity key)" do
        headers = gateway.challenge_headers(mock_request("brc103.identity_key" => "not-a-pubkey"), route)
        expect(headers).to include("x-bsv-payment-identity-key")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # §8.1 Replay Attacks — prefix store
  # ---------------------------------------------------------------------------
  describe "§8.1 — replay protection (prefix store)" do
    it "stores the prefix on challenge issuance" do
      headers = gateway.challenge_headers(mock_request, route)
      prefix = headers["x-bsv-payment-derivation-prefix"]
      expect(prefix_store.valid?(prefix)).to be true
    end

    it "raises 503 when prefix store is at capacity" do
      full_store = X402::BSV::PrefixStore::Memory.new(max_issued: 0)
      full_gateway = described_class.new(key_deriver: key_deriver, prefix_store: full_store, wallet: wallet)

      expect { full_gateway.challenge_headers(mock_request, route) }
        .to raise_error(X402::VerificationError, /at capacity/) { |e| expect(e.status).to eq(503) }
    end
  end

  # ---------------------------------------------------------------------------
  # §5.2 — proof header
  # ---------------------------------------------------------------------------
  describe "§5.2 — proof header names" do
    it "returns x-bsv-payment" do
      expect(gateway.proof_header_names).to eq(["x-bsv-payment"])
    end
  end

  # ---------------------------------------------------------------------------
  # §6.3 Client Payment Submission / §6.4 Server Payment Verification
  # ---------------------------------------------------------------------------
  describe "§6.3/§6.4 — settlement (settle!)" do
    # Use real SDK objects for settle! tests
    let(:server_key) { BSV::Primitives::PrivateKey.generate }
    let(:real_key_deriver) { BSV::Wallet::KeyDeriver.new(server_key) }
    let(:arc_client) { instance_double(BSV::Network::ARC) }
    let(:real_gateway) do
      described_class.new(
        key_deriver: real_key_deriver,
        prefix_store: prefix_store,
        wallet: wallet,
        arc_client: arc_client
      )
    end

    let(:client_key) { BSV::Primitives::PrivateKey.generate }
    let(:client_identity_key) { client_key.public_key.to_hex }
    let(:prefix) { SecureRandom.hex(16) }
    let(:suffix) { SecureRandom.hex(16) }
    let(:request) { mock_request("brc103.identity_key" => client_identity_key) }

    # Derive the expected payment script (same logic as the gateway)
    let(:derived_pubkey) do
      real_key_deriver.derive_public_key(
        [2, "3241645161d8"], "#{prefix} #{suffix}", client_identity_key, for_self: true
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

    # Atomic BEEF: subject_txid set → settle_payment! calls arc.status
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
      allow(wallet).to receive(:internalize_action).and_return({ accepted: true })
      # Default: ARC confirms the tx is on-chain. Status-only — no broadcast.
      allow(arc_client).to receive(:status).and_return(instance_double(BSV::Network::BroadcastResponse))
    end

    # §6.4 step 2: "Ensuring the output script pays to the correct derivation"
    #              "Checking if the amount is at least the required satoshisRequired"
    context "valid payment" do
      it "returns a SettlementResult with txid and network" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(result).to be_a(X402::SettlementResult)
        expect(result.txid).to eq(transaction.txid_hex)
        expect(result.network).to eq("bsv:mainnet")
      end

      it "calls wallet.internalize_action with correct derivation params" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(wallet).to have_received(:internalize_action).with(hash_including(
                                                                    tx: an_instance_of(Array),
                                                                    outputs: [hash_including(
                                                                      output_index: 0,
                                                                      protocol: "wallet payment",
                                                                      payment_remittance: {
                                                                        derivation_prefix: prefix,
                                                                        derivation_suffix: suffix,
                                                                        sender_identity_key: client_identity_key
                                                                      }
                                                                    )],
                                                                    description: "BRC-105 payment"
                                                                  ))
      end
    end

    # §6.5 Response to Payment-Funded Request
    context "§6.5 — success response headers" do
      it "includes x-bsv-payment-result receipt" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(result.receipt_headers).to have_key("x-bsv-payment-result")
      end

      # §6.5: "x-bsv-payment-satoshis-paid: <value>"
      it "includes x-bsv-payment-satoshis-paid with actual amount paid" do
        transaction = build_payment_tx(amount: 1500, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(result.receipt_headers["x-bsv-payment-satoshis-paid"]).to eq("1500")
      end
    end

    # §6.4 step 1: "Ensures the prefix is the same as previously advertised
    #               (and not used before)"
    # §8.1: "each derivationPrefix can only be used once"
    context "§8.1 — replay protection" do
      it "rejects a replayed prefix" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /replay/) { |e| expect(e.status).to eq(400) }
      end
    end

    # §8.3: "The server should reject transactions that pay less than required."
    context "§8.3 — underpayment" do
      it "rejects payment below satoshisRequired" do
        transaction = build_payment_tx(amount: 999, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /no output pays/) { |e| expect(e.status).to eq(402) }
      end
    end

    # §6.4 step 2: "Ensuring the output script pays to the correct derivation"
    context "§6.4 — wrong derivation" do
      it "rejects payment to a different derived address" do
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

    # §6.3: Payment JSON must contain derivationPrefix, derivationSuffix, transaction
    context "§6.3 — malformed payment submission" do
      it "rejects invalid JSON" do
        expect { real_gateway.settle!("x-bsv-payment", "not{json", request, route) }
          .to raise_error(X402::VerificationError, /invalid payment JSON/) { |e| expect(e.status).to eq(400) }
      end

      it "rejects missing derivationPrefix" do
        payload = JSON.generate({ "derivationSuffix" => suffix, "transaction" => "AA==" })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /missing derivationPrefix/) { |e| expect(e.status).to eq(400) }
      end

      it "rejects nil derivationSuffix" do
        payload = JSON.generate({ "derivationPrefix" => prefix, "transaction" => "AA==" })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /missing derivationSuffix/) { |e| expect(e.status).to eq(400) }
      end

      it "rejects empty derivationSuffix" do
        payload = JSON.generate({ "derivationPrefix" => prefix, "derivationSuffix" => "", "transaction" => "AA==" })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /invalid derivationSuffix format/) { |e| expect(e.status).to eq(400) }
      end

      it "rejects non-hex derivationPrefix" do
        payload = JSON.generate(
          "derivationPrefix" => "SGVsbG8=", "derivationSuffix" => suffix, "transaction" => "AA=="
        )

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /invalid derivationPrefix format/) { |e| expect(e.status).to eq(400) }
      end

      # BRC-105/BRC-121: suffix is client-generated, reference impls use base64
      it "accepts base64 derivationSuffix" do
        b64_suffix = Base64.strict_encode64(SecureRandom.random_bytes(16))
        b64_derived = real_key_deriver.derive_public_key(
          [2, "3241645161d8"], "#{prefix} #{b64_suffix}", client_identity_key, for_self: true
        )
        h160 = b64_derived.hash160.unpack1("H*")
        b64_script = "76a914#{h160}88ac"

        transaction = build_payment_tx(amount: 1000, script_hex: b64_script)
        payload = build_proof_payload(prefix: prefix, suffix: b64_suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, request, route)
        expect(result).to be_a(X402::SettlementResult)
      end

      it "rejects missing transaction" do
        payload = JSON.generate({ "derivationPrefix" => prefix, "derivationSuffix" => suffix })

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /missing transaction/) { |e| expect(e.status).to eq(400) }
      end
    end

    # Wallet internalisation failure
    context "internalisation failure" do
      it "raises 402 when wallet.internalize_action fails" do
        allow(wallet).to receive(:internalize_action).and_raise(StandardError, "wallet unavailable")
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /payment internalisation failed/) { |e| expect(e.status).to eq(402) }
      end
    end

    # §7.1: "If not authenticated, respond 401 Unauthorized."
    context "§7.1 — missing client identity key" do
      let(:unauthenticated_request) { mock_request }

      it "rejects settlement without x-bsv-auth-identity-key" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        expect { real_gateway.settle!("x-bsv-payment", payload, unauthenticated_request, route) }
          .to raise_error(X402::VerificationError, /missing client identity key/) { |e| expect(e.status).to eq(401) }
      end
    end

    # NO PAY -> NO CONTENT: verify the tx is on-chain via ARC status
    # before consuming prefix or calling internalizeAction.
    # Client broadcasts (BRC-105 §6.3); we just check status.
    context "on-chain verification (NO PAY -> NO CONTENT)" do
      it "calls arc_client.status with the subject txid" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(arc_client).to have_received(:status).with(transaction.txid_hex)
      end

      it "settles successfully, consumes the prefix, and calls internalize_action" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

        result = real_gateway.settle!("x-bsv-payment", payload, request, route)

        expect(result).to be_a(X402::SettlementResult)
        expect(prefix_store.valid?(prefix)).to be false
        expect(wallet).to have_received(:internalize_action)
      end

      it "raises VerificationError(402) when tx is not on-chain" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)
        allow(arc_client).to receive(:status)
          .and_raise(BSV::Network::BroadcastError.new("tx not found", status_code: 404))

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /payment not accepted/) { |e| expect(e.status).to eq(402) }
      end

      it "does NOT consume the prefix when verification fails" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)
        allow(arc_client).to receive(:status)
          .and_raise(BSV::Network::BroadcastError.new("tx not found", status_code: 404))
        allow(prefix_store).to receive(:consume!).and_call_original

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError)

        expect(prefix_store).not_to have_received(:consume!)
        expect(prefix_store.valid?(prefix)).to be true
      end

      it "does NOT call wallet.internalize_action when verification fails" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)
        allow(arc_client).to receive(:status)
          .and_raise(BSV::Network::BroadcastError.new("tx not found", status_code: 404))

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError)

        expect(wallet).not_to have_received(:internalize_action)
      end

      it "raises VerificationError(503) when ARC returns a 5xx" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)
        allow(arc_client).to receive(:status)
          .and_raise(BSV::Network::BroadcastError.new("boom", status_code: 500))

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /temporarily unavailable/) { |e| expect(e.status).to eq(503) }
      end

      it "raises VerificationError(503) on network error" do
        transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
        payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)
        allow(arc_client).to receive(:status).and_raise(SocketError.new("dns fail"))

        expect { real_gateway.settle!("x-bsv-payment", payload, request, route) }
          .to raise_error(X402::VerificationError, /temporarily unavailable/) { |e| expect(e.status).to eq(503) }
      end

      context "when arc_client is nil" do
        it "raises a configuration error" do
          gateway_without_arc = described_class.new(
            key_deriver: real_key_deriver, prefix_store: prefix_store, wallet: wallet
          )
          transaction = build_payment_tx(amount: 1000, script_hex: payment_script_hex)
          payload = build_proof_payload(prefix: prefix, suffix: suffix, transaction: transaction)

          expect { gateway_without_arc.settle!("x-bsv-payment", payload, request, route) }
            .to raise_error(X402::VerificationError, /arc_client is required/) { |e| expect(e.status).to eq(500) }
        end
      end
    end
  end
end
