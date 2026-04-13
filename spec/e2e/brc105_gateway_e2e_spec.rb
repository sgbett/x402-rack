# frozen_string_literal: true

# End-to-end test for BRC105Gateway against BSV testnet.
#
# Environment variables:
#   SERVER_WIF       - server identity key in WIF format (testnet)
#   CLIENT_WIF       - client wallet private key in WIF format (testnet)
#   ARC_URL          - ARC endpoint (default: https://testnet.arcade.gorillapool.io)
#   ARC_API_KEY      - ARC API key
#
# Two wallets:
#   SERVER_WIF  - server's BRC-42 identity key (used by KeyDeriver)
#   CLIENT_WIF  - client's funding wallet
#
# Flow:
#   Server challenges → Client derives address → Client builds + funds tx →
#   Client encodes AtomicBEEF → Server verifies + broadcasts
#
# Run:
#   bundle exec rspec spec/e2e/brc105_gateway_e2e_spec.rb

require_relative "e2e_helper"
require_relative "e2e_logger"
require "bsv-wallet"

RSpec.describe "BRC105Gateway e2e", :e2e do
  let(:server_wif) { ENV.fetch("SERVER_WIF") { skip "SERVER_WIF not set" } }
  let(:client_wif) { ENV.fetch("CLIENT_WIF") { skip "CLIENT_WIF not set" } }
  let(:arc_url) { ENV.fetch("ARC_URL", "https://testnet.arcade.gorillapool.io") }
  let(:arc_api_key) { ENV.fetch("ARC_API_KEY") { skip "ARC_API_KEY not set" } }

  let(:server_key) { BSV::Primitives::PrivateKey.from_wif(server_wif) }
  let(:client_key) { BSV::Primitives::PrivateKey.from_wif(client_wif) }
  let(:provider) { BSV::Network::WhatsOnChain.new(network: :testnet) }
  let(:client_wallet) { BSV::Wallet::Wallet.new(private_key: client_key, provider: provider) }
  let(:arc) { BSV::Network::ARC.new(arc_url, api_key: arc_api_key) }

  let(:server_deriver) { BSV::Wallet::KeyDeriver.new(server_key) }
  let(:prefix_store) { X402::BSV::PrefixStore::Memory.new }
  let(:gateway) do
    X402::BSV::BRC105Gateway.new(
      key_deriver: server_deriver,
      prefix_store: prefix_store,
      arc_client: arc
    )
  end

  let(:route) do
    X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 500)
  end

  let(:brc29_protocol_id) { [2, "3241645161d8"].freeze }

  describe "full BRC-105 standalone payment flow" do
    it "server challenges → client derives + pays → server verifies + broadcasts" do
      log_path = E2ELogger.start_log("brc105-gateway-e2e")
      E2ELogger.header("BRC105Gateway BRC-105 Standalone — BSV Testnet E2E")

      E2ELogger.wallets(
        client_addr: client_key.public_key.address(network: :testnet)
      )
      E2ELogger.emit "  🖥  Server identity   #{server_deriver.identity_key[0..20]}..."
      E2ELogger.emit ""

      E2ELogger.separator

      # Step 1: Server issues challenge
      E2ELogger.step(1, :server, "Issue 402 challenge with BRC-105 headers")
      request = Rack::Request.new(
        Rack::MockRequest.env_for("/premium", method: "GET")
      )

      challenge_headers = gateway.challenge_headers(request, route)

      E2ELogger.arrow(:server, :client, "HTTP/1.1 402 Payment Required")
      E2ELogger.result("x-bsv-payment-satoshis-required", challenge_headers["x-bsv-payment-satoshis-required"])
      E2ELogger.result("x-bsv-payment-derivation-prefix", challenge_headers["x-bsv-payment-derivation-prefix"])
      E2ELogger.result("x-bsv-payment-identity-key", "#{challenge_headers["x-bsv-payment-identity-key"][0..20]}...")

      prefix = challenge_headers["x-bsv-payment-derivation-prefix"]
      server_identity_key_hex = challenge_headers["x-bsv-payment-identity-key"]
      amount = challenge_headers["x-bsv-payment-satoshis-required"].to_i

      expect(prefix).to match(/\A[0-9a-f]{32}\z/)
      expect(server_identity_key_hex).to eq(server_deriver.identity_key)
      expect(amount).to eq(500)

      E2ELogger.separator

      # Step 2: Client derives payment address using BRC-29
      E2ELogger.step(2, :client, "Derive payment address via BRC-29")

      suffix = SecureRandom.hex(16)
      key_id = "#{prefix} #{suffix}"

      # Client uses "anyone" key (standalone mode) + server's identity as counterparty
      # BRC-42 ECDH: anyone_pub.derive_child(server_priv, invoice) on server side
      #              server_pub.derive_child(anyone_priv, invoice) on client side
      client_deriver = BSV::Wallet::KeyDeriver.new("anyone")
      derived_pubkey = client_deriver.derive_public_key(
        brc29_protocol_id, key_id, server_identity_key_hex, for_self: false
      )
      h160 = derived_pubkey.hash160.unpack1("H*")
      payment_script = BSV::Script::Script.from_hex("76a914#{h160}88ac")

      E2ELogger.result("Protocol ID", "[2, \"3241645161d8\"]")
      E2ELogger.result("Key ID", "\"#{prefix[0..8]}... #{suffix[0..8]}...\"")
      E2ELogger.result("Counterparty", "server identity key (standalone mode)")
      E2ELogger.result("Derived P2PKH", "76a914#{h160[0..12]}...88ac")

      E2ELogger.separator

      # Step 3: Client builds and funds transaction
      E2ELogger.step(3, :client, "Build payment transaction to derived address")

      transaction = BSV::Transaction::Transaction.new
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: amount,
                               locking_script: payment_script
                             ))

      client_wallet.fund_and_sign(transaction, network: :testnet)

      E2ELogger.result("Inputs", transaction.inputs.size.to_s)
      E2ELogger.result("Outputs", transaction.outputs.size.to_s)
      transaction.outputs.each_with_index do |output, idx|
        if output.satoshis == amount
          E2ELogger.result("  Output #{idx}", "#{output.satoshis} sats (payment to derived address)")
        else
          E2ELogger.result("  Output #{idx}", "#{output.satoshis} sats (change)")
        end
      end

      E2ELogger.separator

      # Step 4: Client encodes as AtomicBEEF
      E2ELogger.step(4, :client, "Encode transaction as AtomicBEEF (BRC-95)")

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(transaction)
      atomic_binary = beef.to_atomic_binary(transaction.txid)
      atomic_b64 = Base64.strict_encode64(atomic_binary)

      payment_json = JSON.generate({
                                     "derivationPrefix" => prefix,
                                     "derivationSuffix" => suffix,
                                     "transaction" => atomic_b64
                                   })

      E2ELogger.result("AtomicBEEF size", "#{atomic_binary.bytesize} bytes")
      E2ELogger.result("Base64 size", "#{atomic_b64.length} chars")
      E2ELogger.result("x-bsv-payment", "#{payment_json[0..60]}...")

      E2ELogger.separator

      # Step 5: Client submits payment
      E2ELogger.step(5, :client, "Submit payment to server")
      E2ELogger.arrow(:client, :server, "GET /premium")
      E2ELogger.result("x-bsv-payment", "(JSON with prefix, suffix, AtomicBEEF)")

      E2ELogger.separator

      # Step 6: Server verifies and broadcasts
      E2ELogger.step(6, :server, "Verify BRC-29 derivation and broadcast via ARC")
      E2ELogger.result("Verify", "parse BEEF, re-derive address, check output >= #{amount} sats")
      E2ELogger.result("Counterparty", "\"anyone\" (standalone mode)")
      E2ELogger.arrow(:server, :arc, "POST /v1/tx (broadcast)")

      result = gateway.settle!("x-bsv-payment", payment_json, request, route)

      E2ELogger.arrow(:arc, :server, "HTTP/1.1 200 OK")

      expect(result).to be_a(X402::SettlementResult)
      expect(result.txid).to eq(transaction.txid_hex)
      expect(result.network).to eq("bsv:mainnet")
      expect(result.receipt_headers).to have_key("x-bsv-payment-result")

      receipt_json = JSON.parse(Base64.strict_decode64(result.receipt_headers["x-bsv-payment-result"]))
      E2ELogger.tx("Settlement tx", receipt_json["transaction"])
      E2ELogger.result("ARC status", "accepted")

      E2ELogger.separator

      # Result
      E2ELogger.arrow(:server, :client, "HTTP/1.1 200 OK")
      E2ELogger.result("x-bsv-payment-result", "#{result.receipt_headers["x-bsv-payment-result"][0..40]}...")
      E2ELogger.result("Content", "<protected content served>")

      E2ELogger.success("BRC-105 payment accepted — content served")

      E2ELogger.separator
      E2ELogger.emit "  On-chain artefacts:"
      E2ELogger.tx("  Payment", result.txid)
      E2ELogger.emit ""
      E2ELogger.emit "  Transaction breakdown:"
      E2ELogger.emit "    Output 0: #{amount} sats → BRC-29 derived P2PKH (server can spend)"
      transaction.outputs[1..].each_with_index do |output, idx|
        E2ELogger.emit "    Output #{idx + 1}: #{output.satoshis} sats → change"
      end

      E2ELogger.separator

      # Verify replay protection
      E2ELogger.step(7, :server, "Verify replay protection — same prefix rejected")
      expect { gateway.settle!("x-bsv-payment", payment_json, request, route) }
        .to raise_error(X402::VerificationError, /replay/)
      E2ELogger.result("Replay", "rejected (prefix already consumed)")

      E2ELogger.success("Replay protection confirmed")
    ensure
      E2ELogger.finish_log
      E2ELogger.emit "  Log: #{log_path}" if log_path
    end
  end

  describe "error cases" do
    it "returns 402 when x-bsv-payment is not provided" do
      request = Rack::Request.new(
        Rack::MockRequest.env_for("/premium", method: "GET")
      )
      headers = gateway.challenge_headers(request, route)

      expect(headers).to include("x-bsv-payment-satoshis-required")
      expect(headers).to include("x-bsv-payment-derivation-prefix")
      expect(headers).to include("x-bsv-payment-identity-key")
    end

    it "rejects payment with wrong derivation suffix" do
      request = Rack::Request.new(
        Rack::MockRequest.env_for("/premium", method: "GET")
      )
      challenge_headers = gateway.challenge_headers(request, route)
      prefix = challenge_headers["x-bsv-payment-derivation-prefix"]

      # Client derives with correct prefix but server will verify with wrong suffix
      correct_suffix = SecureRandom.hex(16)
      wrong_suffix = SecureRandom.hex(16)

      client_deriver = BSV::Wallet::KeyDeriver.new("anyone")
      derived_pubkey = client_deriver.derive_public_key(
        brc29_protocol_id, "#{prefix} #{correct_suffix}",
        server_deriver.identity_key, for_self: false
      )
      h160 = derived_pubkey.hash160.unpack1("H*")
      payment_script = BSV::Script::Script.from_hex("76a914#{h160}88ac")

      transaction = BSV::Transaction::Transaction.new
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: 500,
                               locking_script: payment_script
                             ))
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: ["ee" * 32].pack("H*"),
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(transaction)
      atomic_b64 = Base64.strict_encode64(beef.to_atomic_binary(transaction.txid))

      # Submit with wrong suffix — server will derive a different address
      payment_json = JSON.generate({
                                     "derivationPrefix" => prefix,
                                     "derivationSuffix" => wrong_suffix,
                                     "transaction" => atomic_b64
                                   })

      expect { gateway.settle!("x-bsv-payment", payment_json, request, route) }
        .to raise_error(X402::VerificationError, /no output pays/)
    end
  end
end
