# frozen_string_literal: true

# End-to-end test for PayGateway relay mode against a real Node.js BRC-100 wallet.
#
# Starts a Node.js @bsv/simple wallet server as a child process, then boots
# a Rack server in relay mode (operator_wallet_url) to test the full flow:
#   challenge → payment → ARC broadcast → relay_to_wallet → balance check
#
# Environment variables:
#   CLIENT_WIF  - client wallet private key in WIF format (testnet)
#   ARC_URL     - ARC endpoint (default: https://testnet.arcade.gorillapool.io)
#   ARC_API_KEY - ARC API key
#   WALLET_PORT - Node.js wallet port (default: 9494)
#
# Run:
#   bundle exec rspec spec/e2e/pay_gateway_relay_e2e_spec.rb

require_relative "e2e_helper"
require_relative "e2e_logger"
require "securerandom"

RSpec.describe "PayGateway relay mode (e2e)", :e2e do
  let(:base_url) { "http://localhost:#{@rack_port}" }
  let(:wallet_base_url) { "http://localhost:#{@wallet_port}" }

  before(:all) do
    skip "Node.js required" unless system("node", "--version", out: File::NULL, err: File::NULL)

    fixtures_dir = File.expand_path("fixtures", __dir__)
    unless system("npm", "install", "--silent", chdir: fixtures_dir, out: File::NULL, err: File::NULL)
      skip "npm install failed in #{fixtures_dir}"
    end

    # Auto-generate a fresh wallet key for each run
    server_private_key = SecureRandom.hex(32)
    @wallet_port = Integer(ENV.fetch("WALLET_PORT", "9494"))

    # Start Node.js wallet server
    @wallet_pid = Process.spawn(
      { "SERVER_PRIVATE_KEY" => server_private_key, "WALLET_PORT" => @wallet_port.to_s },
      "node", "wallet-server.mjs",
      chdir: fixtures_dir,
      out: File::NULL,
      err: File::NULL
    )

    # Wait for wallet health check
    wallet_ready = false
    30.times do
      response = Net::HTTP.get_response(URI("http://localhost:#{@wallet_port}/health"))
      if response.code == "200"
        wallet_ready = true
        break
      end
      sleep 0.5
    rescue Errno::ECONNREFUSED
      sleep 0.5
    end
    skip "Node.js wallet server failed to start" unless wallet_ready

    # Set env vars before starting Rack — relay_config.ru reads them at boot
    ENV["ARC_URL"] ||= "https://testnet.arcade.gorillapool.io"
    ENV["OPERATOR_WALLET_URL"] = "http://localhost:#{@wallet_port}/api/server-wallet"

    @rack_server, @rack_thread, @rack_port = E2EHelper.start_server(
      config_ru: File.expand_path("relay_config.ru", __dir__),
      port: 9495
    )

    # Initialise the BRC-100 client wallet — used by all payment tests.
    # sync_utxos discovers on-chain UTXOs at the root address.
    if ENV["CLIENT_WIF"]
      require "bsv-wallet"
      client_key = BSV::Primitives::PrivateKey.from_wif(ENV["CLIENT_WIF"])
      wallet_dir = File.expand_path("../wallet", __dir__)
      @client_wallet = BSV::Wallet::Client.new(
        client_key,
        storage: BSV::Wallet::Store::File.new(dir: wallet_dir),
        network: "testnet",
        broadcaster: BSV::Network::ARC.default(testnet: true),
        chain_data_source: BSV::Network::WhatsOnChain.new(network: :testnet)
      )
      imported = @client_wallet.sync_utxos
      @client_address = client_key.public_key.address(network: :testnet)
      puts "  Client wallet: #{@client_address} (#{@client_wallet.balance} sats, #{imported} UTXOs imported)"
    end
  end

  after(:all) do
    E2EHelper.stop_server(@rack_server, @rack_thread)

    # Sweep wallet funds back to client before shutting down
    if @wallet_port && @client_address
      begin
        uri = URI("http://localhost:#{@wallet_port}/api/server-wallet?action=sweep")
        http = Net::HTTP.new(uri.host, uri.port)
        req = Net::HTTP::Post.new(uri)
        req["Content-Type"] = "application/json"
        req.body = JSON.generate({ address: @client_address })

        response = http.request(req)
        result = JSON.parse(response.body)
        if result["swept"].to_i > 0
          puts "\n  Swept #{result["swept"]} sats back to #{@client_address} (txid: #{result["txid"]})"
        end
      rescue StandardError => e
        puts "\n  Sweep failed (non-fatal): #{e.message}"
      end
    end

    if @wallet_pid
      begin
        Process.kill("TERM", @wallet_pid)
        Process.wait(@wallet_pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # Process already exited — nothing to do
      end
    end
  ensure
    X402.reset_configuration!
  end

  # Build a payment for the given challenge using the BRC-100 client wallet.
  # Uses createAction to construct and broadcast the tx, then wraps the
  # result in a Payment-Signature header.
  def build_payment(challenge)
    accept = challenge["accepts"].first
    amount = accept["amount"].to_i
    payee_hex = accept["payTo"]

    result = @client_wallet.create_action({
                                            description: "e2e relay payment",
                                            outputs: [{
                                              satoshis: amount,
                                              locking_script: payee_hex,
                                              output_description: "payment"
                                            }],
                                            options: { randomize_outputs: false }
                                          })

    # createAction returns tx as AtomicBEEF (number[])
    tx_bytes = result[:tx] || result["tx"]
    txid = result[:txid] || result["txid"]
    beef_b64 = Base64.strict_encode64(tx_bytes.pack("C*"))

    # Extract raw tx from the BEEF for the rawtx field
    beef = BSV::Transaction::Beef.from_binary(tx_bytes.pack("C*"))
    subject_txid = beef.subject_txid || beef.transactions.reverse_each.find(&:transaction)&.txid
    subject_tx = beef.find_transaction(subject_txid)
    rawtx_hex = subject_tx.to_binary.unpack1("H*")

    payload = {
      "x402Version" => 2,
      "accepted" => accept,
      "payload" => {
        "rawtx" => rawtx_hex,
        "txid" => txid,
        "beef" => beef_b64
      }
    }

    Base64.strict_encode64(JSON.generate(payload))
  end

  describe "challenge" do
    it "returns 402 with derivation params" do
      uri = URI("#{base_url}/protected")
      response = Net::HTTP.get_response(uri)

      expect(response.code).to eq("402")
      expect(response["payment-required"]).not_to be_nil

      challenge = E2EHelper.parse_challenge(response)
      expect(challenge["x402Version"]).to eq(2)
      expect(challenge["accepts"]).to be_an(Array)

      accept = challenge["accepts"].first
      expect(accept["network"]).to eq("bsv:testnet")
      expect(accept["asset"]).to eq("BSV")
      expect(accept["amount"]).to eq("2000")
      expect(accept.dig("extra", "derivationPrefix")).not_to be_empty
      expect(accept.dig("extra", "derivationSuffix")).not_to be_empty
    end
  end

  describe "full payment flow" do
    before do
      skip "CLIENT_WIF required" unless ENV["CLIENT_WIF"]
      skip "Client wallet has no funds" unless @client_wallet&.balance&.positive?
    end

    it "returns 200 after valid payment" do
      log_path = E2ELogger.start_log("pay-gateway-relay-e2e")
      E2ELogger.header("PayGateway Relay Mode — BSV Testnet E2E")
      E2ELogger.wallets(client_addr: @client_address)
      E2ELogger.separator

      # Step 1: Request protected resource
      E2ELogger.step(1, :client, "Request protected resource")
      uri = URI("#{base_url}/protected")
      E2ELogger.arrow(:client, :server, "GET /protected")

      challenge_response = Net::HTTP.get_response(uri)
      expect(challenge_response.code).to eq("402")

      E2ELogger.arrow(:server, :client, "HTTP/1.1 402 Payment Required")
      challenge = E2EHelper.parse_challenge(challenge_response)
      accept = challenge["accepts"].first
      E2ELogger.result("Network", accept["network"])
      E2ELogger.result("Amount", "#{accept["amount"]} sats")
      E2ELogger.result("derivationPrefix", accept.dig("extra", "derivationPrefix"))
      E2ELogger.result("derivationSuffix", accept.dig("extra", "derivationSuffix"))
      E2ELogger.separator

      # Step 2: Build payment via BRC-100 wallet
      E2ELogger.step(2, :client, "Build payment via createAction")
      payment_header = build_payment(challenge)
      E2ELogger.result("Payment-Signature", "#{payment_header[0..40]}...")
      E2ELogger.separator

      # Step 3: Submit payment
      E2ELogger.step(3, :client, "Submit payment")
      E2ELogger.arrow(:client, :server, "GET /protected")

      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri)
      request["Payment-Signature"] = payment_header
      E2ELogger.separator

      # Step 4: Server verifies, broadcasts, and relays
      E2ELogger.step(4, :server, "Verify payment, broadcast via ARC, relay to wallet")
      E2ELogger.arrow(:server, :arc, "POST /v1/tx (X-WaitFor: SEEN_ON_NETWORK)")

      response = http.request(request)

      if response.code == "200"
        E2ELogger.arrow(:arc, :server, "HTTP/1.1 200 OK")

        if response["payment-response"]
          receipt = JSON.parse(Base64.strict_decode64(response["payment-response"]))
          E2ELogger.tx("Settlement tx", receipt["transaction"])
        end

        E2ELogger.separator
        E2ELogger.arrow(:server, :client, "HTTP/1.1 200 OK")
        body = JSON.parse(response.body)
        E2ELogger.result("Body", body.to_json)
        E2ELogger.success("Payment accepted — content served via relay")
      else
        E2ELogger.arrow(:arc, :server, "HTTP/1.1 #{response.code}")
        E2ELogger.failure("Payment failed: #{response.body[0..80]}")
      end

      expect(response.code).to eq("200")
      body = JSON.parse(response.body)
      expect(body["secret"]).to eq("you paid for this")

      if response["payment-response"]
        receipt = JSON.parse(Base64.strict_decode64(response["payment-response"]))
        expect(receipt["success"]).to be true
        expect(receipt["network"]).to eq("bsv:testnet")
        expect(receipt["transaction"]).not_to be_empty
      end
    ensure
      E2ELogger.finish_log
      E2ELogger.emit "  Log: #{log_path}" if log_path
    end

    it "increases wallet balance after settlement" do
      # Record pre-payment balance
      pre_uri = URI("#{wallet_base_url}/api/server-wallet?action=balance")
      pre_response = Net::HTTP.get_response(pre_uri)
      pre_balance = JSON.parse(pre_response.body)["spendableSatoshis"] || 0

      # Get challenge
      uri = URI("#{base_url}/protected")
      challenge_response = Net::HTTP.get_response(uri)
      challenge = E2EHelper.parse_challenge(challenge_response)

      # Build and submit payment via BRC-100 wallet
      payment_header = build_payment(challenge)
      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri)
      request["Payment-Signature"] = payment_header

      response = http.request(request)
      expect(response.code).to eq("200")

      # Check post-payment balance (retry up to 3 times for propagation)
      post_balance = nil
      3.times do
        post_response = Net::HTTP.get_response(pre_uri)
        post_balance = JSON.parse(post_response.body)["spendableSatoshis"] || 0
        break if post_balance > pre_balance

        sleep 1
      end

      expect(post_balance).to be > pre_balance
    end
  end

  describe "error cases" do
    it "returns 402 without Payment-Signature" do
      uri = URI("#{base_url}/protected")
      response = Net::HTTP.get_response(uri)
      expect(response.code).to eq("402")
    end

    it "passes through unprotected routes" do
      uri = URI("#{base_url}/")
      response = Net::HTTP.get_response(uri)
      expect(response.code).to eq("200")
      expect(response.body).to eq("OK")
    end
  end
end
