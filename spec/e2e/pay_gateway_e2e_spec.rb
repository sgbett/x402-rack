# frozen_string_literal: true

# End-to-end test for PayGateway against BSV testnet.
#
# Prerequisites:
#   - BSV testnet wallet with funded UTXOs
#   - ARC testnet endpoint
#
# Environment variables:
#   CLIENT_WIF       - client wallet private key in WIF format (testnet)
#   PAYEE_SCRIPT     - payee locking script hex
#   ARC_URL          - ARC endpoint (default: https://arc-test.taal.com)
#   ARC_API_KEY      - ARC API key (optional)
#
# Run:
#   bundle exec rspec spec/e2e/pay_gateway_e2e_spec.rb

require_relative "e2e_helper"

RSpec.describe "PayGateway e2e", :e2e do
  let(:client_wif) { ENV.fetch("CLIENT_WIF") { skip "CLIENT_WIF not set" } }
  let(:payee_script_hex) { ENV.fetch("PAYEE_SCRIPT") { skip "PAYEE_SCRIPT not set" } }
  let(:arc_url) { ENV.fetch("ARC_URL", "https://arc-test.taal.com") }
  let(:base_url) { "http://localhost:#{@port}" }

  before(:all) do
    ENV["ARC_URL"] ||= "https://arc-test.taal.com"
    ENV["PAYEE_SCRIPT"] ||= "76a914#{"00" * 20}88ac" # placeholder, overridden by env

    @server, @thread, @port = E2EHelper.start_server(
      config_ru: File.expand_path("config.ru", __dir__)
    )
  end

  after(:all) do
    E2EHelper.stop_server(@server, @thread)
    X402.reset_configuration!
  end

  describe "full payment flow" do
    it "returns 402 with Payment-Required header for unprotected request" do
      uri = URI("#{base_url}/protected")
      response = Net::HTTP.get_response(uri)

      expect(response.code).to eq("402")
      expect(response["payment-required"]).not_to be_nil

      challenge = E2EHelper.parse_challenge(response)
      expect(challenge["x402Version"]).to eq(2)
      expect(challenge["accepts"]).to be_an(Array)
      expect(challenge["accepts"].first["network"]).to eq("bsv:mainnet")
      expect(challenge["accepts"].first["asset"]).to eq("BSV")
    end

    it "returns 200 with content after valid payment" do
      # Step 1: Get the challenge
      uri = URI("#{base_url}/protected")
      challenge_response = Net::HTTP.get_response(uri)
      expect(challenge_response.code).to eq("402")

      challenge = E2EHelper.parse_challenge(challenge_response)
      accept = challenge["accepts"].first
      amount = accept["amount"].to_i
      payee_hex = accept["payTo"]

      # Step 2: Build the payment transaction
      client_key = BSV::Primitives::PrivateKey.from_wif(client_wif)
      payee_script = BSV::Script::Script.from_hex(payee_hex)

      # If there's a partial tx template, extend it
      if accept.dig("extra", "partialTx")
        template_binary = Base64.strict_decode64(accept["extra"]["partialTx"])
        transaction = BSV::Transaction::Transaction.from_binary(template_binary)
      else
        transaction = BSV::Transaction::Transaction.new
        transaction.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: amount,
                                 locking_script: payee_script
                               ))
      end

      # Add a funded input from the client wallet
      # This requires the client wallet to have UTXOs — uses the SDK's wallet
      wallet = BSV::Wallet::Wallet.new(private_key: client_key)
      wallet.fund_and_sign(transaction)

      # Step 3: Submit payment
      payment_header = E2EHelper.build_payment_signature(challenge, transaction)

      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri)
      request["Payment-Signature"] = payment_header

      response = http.request(request)

      # Step 4: Verify
      expect(response.code).to eq("200")

      body = JSON.parse(response.body)
      expect(body["secret"]).to eq("you paid for this")

      # Check receipt header
      if response["payment-response"]
        receipt = JSON.parse(Base64.strict_decode64(response["payment-response"]))
        expect(receipt["success"]).to be true
        expect(receipt["network"]).to eq("bsv:mainnet")
        expect(receipt["transaction"]).not_to be_empty
      end
    end
  end

  describe "error cases" do
    it "returns 402 when Payment-Signature is missing" do
      uri = URI("#{base_url}/protected")
      response = Net::HTTP.get_response(uri)
      expect(response.code).to eq("402")
    end

    it "returns error when payment is insufficient" do
      # Get challenge
      uri = URI("#{base_url}/protected")
      challenge_response = Net::HTTP.get_response(uri)
      challenge = E2EHelper.parse_challenge(challenge_response)

      # Build a tx that pays 0 sats (insufficient)
      payee_script = BSV::Script::Script.from_hex(challenge["accepts"].first["payTo"])
      transaction = BSV::Transaction::Transaction.new
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: 0,
                               locking_script: payee_script
                             ))

      # Add a dummy input
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: ["dd" * 32].pack("H*"),
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))

      payment_header = E2EHelper.build_payment_signature(challenge, transaction)

      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri)
      request["Payment-Signature"] = payment_header

      response = http.request(request)
      expect(response.code.to_i).to be >= 400
    end
  end
end
