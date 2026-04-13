# frozen_string_literal: true

require_relative "e2e_helper"
require_relative "e2e_logger"

RSpec.describe "ProofGateway e2e (Profile B)", :e2e do
  let(:treasury_wif) { ENV.fetch("TREASURY_WIF") { skip "TREASURY_WIF not set" } }
  let(:client_wif) { ENV.fetch("CLIENT_WIF") { skip "CLIENT_WIF not set" } }
  let(:payee_script_hex) { ENV.fetch("PAYEE_SCRIPT") { skip "PAYEE_SCRIPT not set" } }
  let(:arc_url) { ENV.fetch("ARC_URL", "https://testnet.arcade.gorillapool.io") }
  let(:arc_api_key) { ENV.fetch("ARC_API_KEY") { skip "ARC_API_KEY not set" } }

  let(:treasury_key) { BSV::Primitives::PrivateKey.from_wif(treasury_wif) }
  let(:client_key) { BSV::Primitives::PrivateKey.from_wif(client_wif) }
  let(:provider) { BSV::Network::WhatsOnChain.new(network: :testnet) }
  let(:treasury_wallet) { BSV::Wallet::Wallet.new(private_key: treasury_key, provider: provider) }
  let(:client_wallet) { BSV::Wallet::Wallet.new(private_key: client_key, provider: provider) }
  let(:arc) { BSV::Network::ARC.new(arc_url, api_key: arc_api_key) }

  def mint_nonce!
    nonce_script_hex = "76a914#{treasury_key.public_key.hash160.unpack1("H*")}88ac"
    nonce_script = BSV::Script::Script.from_hex(nonce_script_hex)

    tx = BSV::Transaction::Transaction.new
    tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 1, locking_script: nonce_script))
    treasury_wallet.fund_and_sign(tx, network: :testnet)

    result = arc.broadcast(tx, wait_for: "SEEN_ON_NETWORK")

    {
      txid: result.txid,
      vout: 0,
      satoshis: 1,
      locking_script_hex: nonce_script_hex,
      arc_status: result.tx_status
    }
  end

  describe "full Profile B flow with separate wallets" do
    it "treasury mints → server challenges → client pays → server verifies" do
      log_path = E2ELogger.start_log("proof-gateway-e2e")
      E2ELogger.header("ProofGateway Profile B — BSV Testnet E2E")

      E2ELogger.wallets(
        treasury_addr: treasury_key.public_key.address(network: :testnet),
        client_addr: client_key.public_key.address(network: :testnet),
        payee_script: payee_script_hex
      )

      E2ELogger.separator

      # Step 0: Treasury mints nonce
      E2ELogger.step(0, :treasury, "Mint 1-sat nonce UTXO")
      nonce = mint_nonce!
      E2ELogger.tx("Nonce UTXO", nonce[:txid])
      E2ELogger.result("ARC status", nonce[:arc_status])

      # Provider builds and signs the template (treasury responsibility)
      t_key = treasury_key
      nonce_provider = lambda { |_req, payee:, amount:|
        tx = BSV::Transaction::Transaction.new

        nonce_script = BSV::Script::Script.from_hex(nonce[:locking_script_hex])
        nonce_input = BSV::Transaction::TransactionInput.new(
          prev_tx_id: [nonce[:txid]].pack("H*").reverse,
          prev_tx_out_index: nonce[:vout]
        )
        nonce_input.source_satoshis = nonce[:satoshis]
        nonce_input.source_locking_script = nonce_script
        tx.add_input(nonce_input)

        payee_script = BSV::Script::Script.from_hex(payee)
        tx.add_output(BSV::Transaction::TransactionOutput.new(
                        satoshis: amount,
                        locking_script: payee_script
                      ))

        sighash = BSV::Transaction::Sighash::SINGLE_FORK_ID_ANYONE_CAN_PAY
        tx.sign(0, t_key, sighash)

        nonce.merge(partial_tx: tx.to_binary)
      }

      E2ELogger.separator

      # Step 1: Server builds challenge
      E2ELogger.step(1, :server, "Build challenge (Profile B)")
      proof_arc = BSV::Network::ARC.new(arc_url, api_key: arc_api_key)
      gateway = X402::BSV::ProofGateway.new(
        nonce_provider: nonce_provider,
        arc_client: proof_arc,
        payee_locking_script_hex: payee_script_hex
      )

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

      E2ELogger.arrow(:server, :client, "HTTP/1.1 402 Payment Required")
      E2ELogger.result("X402-Challenge", "#{challenge_header[0..40]}...")
      E2ELogger.result("Nonce txid", challenge.nonce_txid[0..15])
      E2ELogger.result("Amount", "#{challenge_data["amount_sats"]} sats")
      E2ELogger.result("Template", "#{challenge_data["partial_tx_b64"][0..30]}... (Profile B signed)")
      expect(challenge_data["partial_tx_b64"]).not_to be_nil

      E2ELogger.separator

      # Step 2: Client extends template
      E2ELogger.step(2, :client, "Decode and extend template")
      template = BSV::Transaction::Transaction.from_binary(
        Base64.strict_decode64(challenge_data["partial_tx_b64"])
      )

      template.inputs[0].source_satoshis = challenge_data["nonce_satoshis"]
      template.inputs[0].source_locking_script = BSV::Script::Script.from_hex(
        challenge_data["nonce_locking_script_hex"]
      )

      E2ELogger.result("Template inputs", template.inputs.size.to_s)
      E2ELogger.result("Template outputs", template.outputs.size.to_s)
      template.outputs.each_with_index do |output, idx|
        if output.locking_script.op_return?
          E2ELogger.result("  Output #{idx}", "OP_RETURN (#{output.locking_script.to_hex.length / 2} bytes)")
        else
          E2ELogger.result("  Output #{idx}", "#{output.satoshis} sats")
        end
      end

      client_wallet.fund_and_sign(template, network: :testnet)
      E2ELogger.result("After funding", "#{template.inputs.size} inputs, #{template.outputs.size} outputs")

      E2ELogger.separator

      # Step 3: Client broadcasts
      E2ELogger.step(3, :client, "Broadcast payment transaction")
      E2ELogger.arrow(:client, :arc, "POST /v1/tx (X-WaitFor: SEEN_ON_NETWORK)")
      broadcast_result = arc.broadcast(template, wait_for: "SEEN_ON_NETWORK")
      E2ELogger.arrow(:arc, :client, "HTTP/1.1 200 OK")
      E2ELogger.tx("Payment tx", broadcast_result.txid)
      E2ELogger.result("ARC status", broadcast_result.tx_status)

      E2ELogger.separator

      # Step 4: Client submits proof
      E2ELogger.step(4, :client, "Submit proof to server")
      proof_data = {
        challenge_sha256: challenge.sha256_hex,
        payment: {
          rawtx_b64: Base64.strict_encode64(template.to_binary),
          txid: template.txid_hex
        }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(proof_data))

      E2ELogger.arrow(:client, :server, "GET /weather?city=lisbon")
      E2ELogger.result("X402-Proof", "#{proof_header[0..40]}...")

      E2ELogger.separator

      # Step 5: Server verifies and settles
      E2ELogger.step(5, :server, "Verify proof and check mempool")
      E2ELogger.result("Protocol checks", "version, scheme, hash, binding, expiry")
      E2ELogger.result("Nonce check", "input[0] = #{challenge.nonce_txid[0..15]}...")
      E2ELogger.result("Provenance", "verify_input(0) — 0xC3 signature")
      E2ELogger.result("Payment", ">= #{route.amount_sats} sats to payee")

      E2ELogger.arrow(:server, :arc, "GET /v1/tx/#{template.txid_hex[0..15]}...")
      result = gateway.settle!("X402-Proof", proof_header, request, route)
      E2ELogger.arrow(:arc, :server, "txStatus: confirmed")

      expect(result).to be_a(X402::SettlementResult)
      expect(result.txid).to eq(template.txid_hex)

      E2ELogger.separator

      # Result
      E2ELogger.arrow(:server, :client, "HTTP/1.1 200 OK")
      E2ELogger.result("Content", "<protected content served>")

      E2ELogger.success("Settlement complete — all checks passed")

      E2ELogger.separator
      puts "  On-chain artefacts:"
      E2ELogger.tx("  Nonce mint", nonce[:txid])
      E2ELogger.tx("  Payment", result.txid)
    ensure
      E2ELogger.finish_log
      E2ELogger.emit "  Log: #{log_path}" if log_path
      X402.reset_configuration!
    end
  end
end
