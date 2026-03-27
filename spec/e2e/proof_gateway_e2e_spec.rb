# frozen_string_literal: true

# End-to-end test for ProofGateway (Profile B) against BSV testnet.
#
# Prerequisites:
#   - BSV testnet wallet with funded UTXOs
#   - ARC testnet endpoint with API key
#
# Environment variables:
#   CLIENT_WIF       - wallet private key in WIF format (testnet)
#   PAYEE_SCRIPT     - payee locking script hex
#   ARC_URL          - ARC endpoint (default: https://arc-test.taal.com)
#   ARC_API_KEY      - ARC API key
#
# Run:
#   bundle exec rspec spec/e2e/proof_gateway_e2e_spec.rb

require_relative "e2e_helper"

RSpec.describe "ProofGateway e2e (Profile B)", :e2e do
  let(:client_wif) { ENV.fetch("CLIENT_WIF") { skip "CLIENT_WIF not set" } }
  let(:payee_script_hex) { ENV.fetch("PAYEE_SCRIPT") { skip "PAYEE_SCRIPT not set" } }
  let(:arc_url) { ENV.fetch("ARC_URL", "https://arc-test.taal.com") }
  let(:arc_api_key) { ENV.fetch("ARC_API_KEY") { skip "ARC_API_KEY not set" } }

  let(:client_key) { BSV::Primitives::PrivateKey.from_wif(client_wif) }
  let(:provider) { BSV::Network::WhatsOnChain.new(network: :testnet) }
  let(:wallet) { BSV::Wallet::Wallet.new(private_key: client_key, provider: provider) }
  let(:arc) { BSV::Network::ARC.new(arc_url, api_key: arc_api_key) }

  # Mint a 1-sat nonce UTXO on testnet. Returns the nonce hash.
  def mint_nonce!
    nonce_script_hex = "76a914#{client_key.public_key.hash160.unpack1("H*")}88ac"
    nonce_script = BSV::Script::Script.from_hex(nonce_script_hex)

    tx = BSV::Transaction::Transaction.new
    tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 1, locking_script: nonce_script))
    wallet.fund_and_sign(tx, network: :testnet)

    result = arc.broadcast(tx, wait_for: "SEEN_ON_NETWORK")
    puts "  Nonce minted: #{result.txid[0..15]}..."

    {
      txid: result.txid,
      vout: 0,
      satoshis: 1,
      locking_script_hex: nonce_script_hex
    }
  end

  describe "full Profile B flow" do
    it "challenge → extend template → broadcast → proof → 200" do
      # Step 0: Mint a nonce UTXO
      nonce = mint_nonce!
      nonce_provider = ->(_req) { nonce }

      # Step 1: Set up ProofGateway with nonce key
      proof_arc = BSV::Network::ARC.new(arc_url, api_key: arc_api_key)
      gateway = X402::BSV::ProofGateway.new(
        nonce_provider: nonce_provider,
        arc_client: proof_arc,
        nonce_key: client_key, # same key — treasury role
        payee_locking_script_hex: payee_script_hex
      )

      # Step 2: Build challenge
      X402.reset_configuration!
      X402.configuration.domain = "localhost"
      X402.configuration.payee_locking_script_hex = payee_script_hex

      request = Rack::Request.new(
        Rack::MockRequest.env_for("/weather?city=lisbon", method: "GET")
      )
      route = X402::Configuration::Route.new(
        http_method: "GET", path: "/weather", amount_sats: 500
      )

      headers = gateway.challenge_headers(request, route)
      challenge_header = headers["X402-Challenge"]
      challenge_json = X402::Base64Url.decode(challenge_header)
      challenge_data = JSON.parse(challenge_json)
      challenge = X402::Challenge.from_header(challenge_header)

      puts "  Challenge issued: #{challenge.nonce_txid[0..15]}..."
      expect(challenge_data["partial_tx_b64"]).not_to be_nil

      # Step 3: Decode and extend the template
      template = BSV::Transaction::Transaction.from_binary(
        Base64.strict_decode64(challenge_data["partial_tx_b64"])
      )

      expect(template.inputs.size).to eq(1) # nonce at index 0
      expect(template.outputs.size).to eq(2) # payment + OP_RETURN

      # Set source info on the nonce input (lost during serialise/deserialise)
      # The client knows these from the challenge data
      template.inputs[0].source_satoshis = challenge_data["nonce_satoshis"]
      template.inputs[0].source_locking_script = BSV::Script::Script.from_hex(
        challenge_data["nonce_locking_script_hex"]
      )

      # Client adds funding inputs
      wallet.fund_and_sign(template, network: :testnet)

      puts "  Template extended: #{template.inputs.size} inputs, #{template.outputs.size} outputs"
      puts "  Payment txid: #{template.txid_hex[0..15]}..."

      # Step 4: Client broadcasts
      broadcast_result = arc.broadcast(template, wait_for: "SEEN_ON_NETWORK")
      puts "  Broadcast: #{broadcast_result.txid[0..15]}... status=#{broadcast_result.tx_status}"

      # Step 5: Submit proof
      proof_data = {
        challenge_sha256: challenge.sha256_hex,
        payment: {
          rawtx_b64: Base64.strict_encode64(template.to_binary),
          txid: template.txid_hex
        }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(proof_data))
      request.env["HTTP_X402_CHALLENGE"] = challenge_header

      # Step 6: Settle
      result = gateway.settle!("X402-Proof", proof_header, request, route)

      expect(result).to be_a(X402::SettlementResult)
      expect(result.txid).to eq(template.txid_hex)
      expect(result.network).to eq("bsv:mainnet")

      puts "  Settlement: OK (txid=#{result.txid[0..15]}...)"
      puts "  View on WoC: https://test.whatsonchain.com/tx/#{result.txid}"
    ensure
      X402.reset_configuration!
    end
  end
end
