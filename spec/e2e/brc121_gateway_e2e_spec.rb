# frozen_string_literal: true

# End-to-end test for BRC121Gateway against BSV testnet.
#
# This test encodes the NO PAY → NO CONTENT invariant as two complementary
# `it` blocks:
#
#   1. Happy path — the client wallet broadcasts its BRC-29 payment via its
#      injected ARC broadcaster, the server gateway receives the five proof
#      headers, verifies the BEEF + output + freshness, and internalises the
#      payment. Broadcast is the wallet's job; the gateway must not attempt
#      to broadcast on the client's behalf.
#
#   2. Exploit path — the client builds a structurally valid BEEF via
#      `create_action(options: { no_send: true })`. The wallet never touches
#      the broadcaster. The client then submits the proof headers to the
#      server as though it had paid. Verification is the gateway's job: on a
#      correct implementation the gateway queries ARC for the txid and
#      refuses to serve content because the transaction is not visible on
#      the network. Neither job can be skipped — this test is the executable
#      regression guard for the invariant.
#
# Environment variables:
#   SERVER_WIF       - server identity key in WIF format (testnet)
#   CLIENT_WIF       - client wallet private key in WIF format (testnet)
#                      (the address derived from this WIF must hold at least
#                      one spendable testnet UTXO — `sync_utxos` imports it)
#   ARC_URL          - ARC endpoint (default: https://testnet.arcade.gorillapool.io)
#   ARC_API_KEY      - ARC API key (optional for some endpoints)
#
# Run:
#   bundle exec rspec spec/e2e/brc121_gateway_e2e_spec.rb --tag e2e

require_relative "e2e_helper"
require_relative "e2e_logger"
require "bsv-wallet"
require "net/http"

RSpec.describe "BRC121Gateway e2e", :e2e do
  let(:server_wif) { ENV.fetch("SERVER_WIF") { skip "SERVER_WIF not set" } }
  let(:client_wif) { ENV.fetch("CLIENT_WIF") { skip "CLIENT_WIF not set" } }
  let(:arc_url) { ENV.fetch("ARC_URL", "https://testnet.arcade.gorillapool.io") }
  let(:arc_api_key) { ENV.fetch("ARC_API_KEY", nil) }

  let(:server_key) { BSV::Primitives::PrivateKey.from_wif(server_wif) }
  let(:client_key) { BSV::Primitives::PrivateKey.from_wif(client_wif) }

  let(:brc29_protocol_id) { [2, "3241645161d8"].freeze }

  # Real ARC broadcaster — wrapped in an rspec spy so the exploit path can
  # assert `not_to receive(:broadcast)` without replacing the broadcast path
  # entirely (the happy path still needs real broadcasting).
  let(:real_arc) { BSV::Network::ARC.new(arc_url, api_key: arc_api_key) }
  let(:broadcaster) do
    spy = instance_double(BSV::Network::ARC)
    allow(spy).to receive(:broadcast) { |*args, **kwargs| real_arc.broadcast(*args, **kwargs) }
    allow(spy).to receive(:broadcast_beef) { |*args, **kwargs| real_arc.broadcast_beef(*args, **kwargs) }
    allow(spy).to receive(:broadcast_many) { |*args, **kwargs| real_arc.broadcast_many(*args, **kwargs) }
    spy
  end

  let(:chain_provider) { BSV::Wallet::WhatsOnChainProvider.new(network: :test) }

  # Client wallet: BRC-100 wallet with broadcaster (real ARC via spy) and
  # chain provider (for `sync_utxos` seeding).
  let(:client_wallet) do
    wallet = BSV::Wallet::WalletClient.new(
      client_key,
      storage: BSV::Wallet::MemoryStore.new,
      network: "testnet",
      chain_provider: chain_provider,
      broadcaster: broadcaster
    )

    imported = wallet.sync_utxos
    skip "CLIENT_WIF address holds no spendable UTXOs on testnet" if imported.zero? && wallet.spendable_balance.zero?

    wallet
  end

  # Server wallet: BRC-100 wallet used by the gateway for identity lookup
  # and `internalize_action`. No broadcaster or chain provider needed.
  let(:server_wallet) do
    BSV::Wallet::WalletClient.new(
      server_key,
      storage: BSV::Wallet::MemoryStore.new,
      network: "testnet"
    )
  end

  let(:gateway) { X402::BSV::BRC121Gateway.new(wallet: server_wallet) }

  let(:route) do
    X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 500)
  end

  # Derive the BRC-29 payment script the client pays to. Mirrors the
  # derivation the server performs when it processes the remittance.
  def derive_payment_script(client_wallet:, server_identity_key_hex:, prefix:, time_ms:)
    suffix = Base64.strict_encode64(time_ms.to_s)
    key_id = "#{prefix} #{suffix}"
    derived_pubkey = client_wallet.key_deriver.derive_public_key(
      brc29_protocol_id, key_id, server_identity_key_hex, for_self: false
    )
    h160 = derived_pubkey.hash160.unpack1("H*")
    [BSV::Script::Script.from_hex("76a914#{h160}88ac"), suffix]
  end

  # Build a GET /premium mock request with the five BRC-121 proof headers.
  def proof_request(beef_b64:, sender:, nonce:, time_ms:, vout:)
    env = Rack::MockRequest.env_for("/premium", method: "GET")
    env["HTTP_X_BSV_BEEF"] = beef_b64
    env["HTTP_X_BSV_SENDER"] = sender
    env["HTTP_X_BSV_NONCE"] = nonce
    env["HTTP_X_BSV_TIME"] = time_ms.to_s
    env["HTTP_X_BSV_VOUT"] = vout.to_s
    Rack::Request.new(env)
  end

  # Poll WhatsOnChain until the txid is visible, or raise with the last
  # response body on timeout. Max wait 30s, poll every 2s.
  def wait_for_woc_visibility(txid, timeout: 30, interval: 2)
    deadline = Time.now + timeout
    last_body = nil
    last_code = nil
    while Time.now < deadline
      response = Net::HTTP.get_response(URI("https://api.whatsonchain.com/v1/bsv/test/tx/#{txid}"))
      last_code = response.code
      last_body = response.body
      if response.code == "200"
        body = JSON.parse(response.body)
        return body if body["txid"] == txid
      end
      sleep interval
    end

    raise "Tx #{txid} not visible on WhatsOnChain within #{timeout}s (last HTTP #{last_code}: #{last_body})"
  end

  describe "full BRC-121 single-round-trip payment flow" do
    it "server challenges → client pays via wallet broadcast → server verifies + internalises" do
      log_path = E2ELogger.start_log("brc121-gateway-e2e-happy")
      E2ELogger.header("BRC121Gateway — Happy Path (BSV Testnet E2E)")

      E2ELogger.wallets(
        client_addr: client_key.public_key.address(network: :testnet)
      )
      server_identity_key_hex = server_wallet.get_public_key(identity_key: true).fetch(:public_key)
      E2ELogger.emit "  🖥  Server identity   #{server_identity_key_hex[0..20]}..."
      E2ELogger.emit ""

      E2ELogger.separator

      # Step 1: Server issues challenge
      E2ELogger.step(1, :server, "Issue 402 challenge with BRC-121 headers")
      challenge_request = Rack::Request.new(Rack::MockRequest.env_for("/premium", method: "GET"))
      challenge_headers = gateway.challenge_headers(challenge_request, route)

      E2ELogger.arrow(:server, :client, "HTTP/1.1 402 Payment Required")
      E2ELogger.result("x-bsv-sats", challenge_headers["x-bsv-sats"])
      E2ELogger.result("x-bsv-server", "#{challenge_headers["x-bsv-server"][0..20]}...")

      amount = challenge_headers["x-bsv-sats"].to_i
      expect(amount).to eq(500)
      expect(challenge_headers["x-bsv-server"]).to eq(server_identity_key_hex)

      E2ELogger.separator

      # Step 2: Client derives payment address (BRC-29, server as counterparty)
      E2ELogger.step(2, :client, "Derive payment address via BRC-29")

      prefix = Base64.strict_encode64(SecureRandom.hex(16))
      time_ms = (Time.now.to_f * 1000).to_i
      payment_script, suffix = derive_payment_script(
        client_wallet: client_wallet,
        server_identity_key_hex: server_identity_key_hex,
        prefix: prefix,
        time_ms: time_ms
      )

      E2ELogger.result("Protocol ID", "[2, \"3241645161d8\"]")
      E2ELogger.result("Key ID", "\"#{prefix[0..8]}... #{suffix[0..8]}...\"")
      E2ELogger.result("Derived P2PKH", "#{payment_script.to_hex[0..30]}...")

      E2ELogger.separator

      # Step 3: Client creates action — wallet broadcasts via injected ARC
      E2ELogger.step(3, :client, "create_action (wallet broadcasts via ARC)")
      result = client_wallet.create_action({
                                             description: "BRC-121 payment",
                                             outputs: [{
                                               locking_script: payment_script.to_hex,
                                               satoshis: amount,
                                               output_description: "BRC-121 payment to server"
                                             }],
                                             auto_fund: true
                                           })

      expect(result[:txid]).to match(/\A[0-9a-f]{64}\z/)
      expect(result[:tx]).to be_a(Array)
      expect(broadcaster).to have_received(:broadcast).at_least(:once)

      beef_bytes = result[:tx].pack("C*")
      beef_b64 = Base64.strict_encode64(beef_bytes)

      E2ELogger.result("Txid", result[:txid])
      E2ELogger.result("BEEF size", "#{beef_bytes.bytesize} bytes")
      E2ELogger.arrow(:client, :arc, "POST /v1/tx (wallet broadcast)")

      E2ELogger.separator

      # Step 4: Locate the payment output vout (auto-fund shuffles outputs)
      subject_tx = BSV::Transaction::Beef.from_binary(beef_bytes).find_transaction(result[:txid])
      vout = subject_tx.outputs.index { |o| o.satoshis == amount && o.locking_script.to_hex == payment_script.to_hex }
      expect(vout).not_to be_nil

      # Step 5: Client submits five BRC-121 proof headers
      E2ELogger.step(4, :client, "Submit five BRC-121 proof headers")
      request = proof_request(
        beef_b64: beef_b64,
        sender: client_wallet.key_deriver.identity_key,
        nonce: prefix,
        time_ms: time_ms,
        vout: vout
      )
      E2ELogger.arrow(:client, :server, "GET /premium")
      E2ELogger.result("x-bsv-beef", "#{beef_b64[0..40]}...")
      E2ELogger.result("x-bsv-sender", "#{client_wallet.key_deriver.identity_key[0..20]}...")
      E2ELogger.result("x-bsv-nonce", prefix)
      E2ELogger.result("x-bsv-time", time_ms.to_s)
      E2ELogger.result("x-bsv-vout", vout.to_s)

      E2ELogger.separator

      # Step 6: Server verifies + internalises
      E2ELogger.step(5, :server, "Verify BEEF + output + freshness + internalise")

      settlement = gateway.settle!("x-bsv-beef", nil, request, route)

      expect(settlement).to be_a(X402::SettlementResult)
      expect(settlement.txid).to eq(result[:txid])
      expect(settlement.receipt_headers["x-bsv-payment-satoshis-paid"]).to eq(amount.to_s)

      E2ELogger.tx("Settlement tx", settlement.txid)
      E2ELogger.success("BRC-121 payment accepted — content served")

      E2ELogger.separator

      # Step 7: Wait for ARC propagation then confirm on WhatsOnChain.
      # Wait ≥15s to exceed the gateway's internal retry budget (see #157).
      E2ELogger.step(6, :client, "Wait ≥15s for ARC propagation, then poll WoC")
      sleep 15
      woc_body = wait_for_woc_visibility(settlement.txid)
      expect(woc_body["txid"]).to eq(settlement.txid)
      E2ELogger.result("WoC visibility", "confirmed")

      E2ELogger.separator

      # Step 8: Replay — second submission must be rejected
      E2ELogger.step(7, :server, "Verify replay protection — same txid rejected")
      replay_request = proof_request(
        beef_b64: beef_b64,
        sender: client_wallet.key_deriver.identity_key,
        nonce: prefix,
        time_ms: time_ms,
        vout: vout
      )
      expect { gateway.settle!("x-bsv-beef", nil, replay_request, route) }
        .to raise_error(X402::VerificationError, /replay: transaction already settled/)
      E2ELogger.result("Replay", "rejected (txid already settled)")

      E2ELogger.success("Replay protection confirmed")
    ensure
      E2ELogger.finish_log
      E2ELogger.emit "  Log: #{log_path}" if log_path
    end
  end

  describe "exploit path — NO PAY → NO CONTENT invariant" do
    it "rejects a structurally valid but un-broadcast BEEF" do
      log_path = E2ELogger.start_log("brc121-gateway-e2e-exploit")
      E2ELogger.header("BRC121Gateway — Exploit Path (TDD guard for #158)")

      server_identity_key_hex = server_wallet.get_public_key(identity_key: true).fetch(:public_key)

      E2ELogger.wallets(
        client_addr: client_key.public_key.address(network: :testnet)
      )
      E2ELogger.emit "  🖥  Server identity   #{server_identity_key_hex[0..20]}..."
      E2ELogger.emit ""
      E2ELogger.separator

      # Server challenge
      E2ELogger.step(1, :server, "Issue 402 challenge")
      challenge_request = Rack::Request.new(Rack::MockRequest.env_for("/premium", method: "GET"))
      challenge_headers = gateway.challenge_headers(challenge_request, route)
      amount = challenge_headers["x-bsv-sats"].to_i

      E2ELogger.separator

      # Derive payment address (same as happy path)
      prefix = Base64.strict_encode64(SecureRandom.hex(16))
      time_ms = (Time.now.to_f * 1000).to_i
      payment_script, = derive_payment_script(
        client_wallet: client_wallet,
        server_identity_key_hex: server_identity_key_hex,
        prefix: prefix,
        time_ms: time_ms
      )

      # THE ATTACK: build a BEEF with no_send — wallet must NOT broadcast.
      E2ELogger.step(2, :client, "create_action(options: { no_send: true }) — construct BEEF, skip broadcast")

      # Pre-assert the broadcaster is untouched on this path.
      expect(broadcaster).not_to receive(:broadcast)
      expect(broadcaster).not_to receive(:broadcast_beef)
      expect(broadcaster).not_to receive(:broadcast_many)

      result = client_wallet.create_action({
                                             description: "BRC-121 exploit (no_send)",
                                             outputs: [{
                                               locking_script: payment_script.to_hex,
                                               satoshis: amount,
                                               output_description: "BRC-121 exploit output"
                                             }],
                                             auto_fund: true,
                                             options: { no_send: true }
                                           })

      expect(result[:txid]).to match(/\A[0-9a-f]{64}\z/)
      expect(result[:tx]).to be_a(Array)

      beef_bytes = result[:tx].pack("C*")
      beef_b64 = Base64.strict_encode64(beef_bytes)

      subject_tx = BSV::Transaction::Beef.from_binary(beef_bytes).find_transaction(result[:txid])
      vout = subject_tx.outputs.index { |o| o.satoshis == amount && o.locking_script.to_hex == payment_script.to_hex }

      E2ELogger.result("Txid", result[:txid])
      E2ELogger.result("Broadcast", "SKIPPED (no_send) — this is the attack")

      E2ELogger.separator

      # Submit the forged proof headers to the gateway.
      E2ELogger.step(3, :client, "Submit proof headers to server (pretending to have paid)")
      request = proof_request(
        beef_b64: beef_b64,
        sender: client_wallet.key_deriver.identity_key,
        nonce: prefix,
        time_ms: time_ms,
        vout: vout
      )

      E2ELogger.separator
      E2ELogger.step(4, :server, "Must verify on-chain visibility before returning 200")

      # TDD guard for #158: this assertion FAILS on 0.10.1 (server returns 200 without verifying).
      # Once #158 ships, the gateway's on-chain visibility check returns 402 and this test passes.
      # DO NOT "fix" this test by changing the expected status on master. The failure IS the regression.
      #
      # The reason-string regex is intentionally broad — #158's implementer defines the exact
      # operator-facing wording. What MUST hold: status 402, and the reason communicates that
      # the payment was not visible on-chain. If the wording diverges, update the regex to
      # match the chosen phrase rather than narrowing the implementation.
      expect { gateway.settle!("x-bsv-beef", nil, request, route) }
        .to raise_error(X402::VerificationError) { |e|
          expect(e.status).to eq(402)
          expect(e.reason).to match(/not visible|payment verification|on.chain|unconfirmed|un.?broadcast/i)
        }

      E2ELogger.success("Exploit rejected — NO PAY → NO CONTENT invariant holds")
    ensure
      E2ELogger.finish_log
      E2ELogger.emit "  Log: #{log_path}" if log_path
    end
  end

  describe "error cases" do
    # Build a valid no_send BEEF so the error-case specs can reuse real proof
    # headers and mutate them. We use no_send to avoid consuming on-chain
    # UTXOs on every error-case example.
    def build_valid_proof(client_wallet:, server_identity_key_hex:, amount:)
      prefix = Base64.strict_encode64(SecureRandom.hex(16))
      time_ms = (Time.now.to_f * 1000).to_i
      payment_script, = derive_payment_script(
        client_wallet: client_wallet,
        server_identity_key_hex: server_identity_key_hex,
        prefix: prefix,
        time_ms: time_ms
      )

      result = client_wallet.create_action({
                                             description: "BRC-121 error-case payment",
                                             outputs: [{
                                               locking_script: payment_script.to_hex,
                                               satoshis: amount,
                                               output_description: "BRC-121 error-case output"
                                             }],
                                             auto_fund: true,
                                             options: { no_send: true }
                                           })

      beef_bytes = result[:tx].pack("C*")
      subject_tx = BSV::Transaction::Beef.from_binary(beef_bytes).find_transaction(result[:txid])
      vout = subject_tx.outputs.index { |o| o.satoshis == amount && o.locking_script.to_hex == payment_script.to_hex }

      {
        beef_b64: Base64.strict_encode64(beef_bytes),
        sender: client_wallet.key_deriver.identity_key,
        nonce: prefix,
        time_ms: time_ms,
        vout: vout
      }
    end

    let(:server_identity_key_hex) { server_wallet.get_public_key(identity_key: true).fetch(:public_key) }

    it "rejects a stale x-bsv-time outside the 30s freshness window" do
      proof = build_valid_proof(
        client_wallet: client_wallet,
        server_identity_key_hex: server_identity_key_hex,
        amount: 500
      )

      stale_time = (Time.now.to_f * 1000).to_i - 60_000
      request = proof_request(
        beef_b64: proof[:beef_b64],
        sender: proof[:sender],
        nonce: proof[:nonce],
        time_ms: stale_time,
        vout: proof[:vout]
      )

      expect { gateway.settle!("x-bsv-beef", nil, request, route) }
        .to raise_error(X402::VerificationError) { |e|
          expect(e.status).to eq(402)
          expect(e.reason).to include("freshness")
        }
    end

    %w[x-bsv-beef x-bsv-sender x-bsv-nonce x-bsv-time x-bsv-vout].each do |header|
      it "rejects when #{header} is missing" do
        proof = build_valid_proof(
          client_wallet: client_wallet,
          server_identity_key_hex: server_identity_key_hex,
          amount: 500
        )

        env = Rack::MockRequest.env_for("/premium", method: "GET")
        env["HTTP_X_BSV_BEEF"] = proof[:beef_b64]
        env["HTTP_X_BSV_SENDER"] = proof[:sender]
        env["HTTP_X_BSV_NONCE"] = proof[:nonce]
        env["HTTP_X_BSV_TIME"] = proof[:time_ms].to_s
        env["HTTP_X_BSV_VOUT"] = proof[:vout].to_s
        env.delete("HTTP_#{header.upcase.tr("-", "_")}")

        expect { gateway.settle!("x-bsv-beef", nil, Rack::Request.new(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(402)
            expect(e.reason).to include(header)
          }
      end
    end
  end
end
