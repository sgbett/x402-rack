# frozen_string_literal: true

# End-to-end test for PayGateway against BSV testnet.
#
# Environment variables:
#   CLIENT_WIF       - client wallet private key in WIF format (testnet)
#   PAYEE_SCRIPT     - payee locking script hex
#   ARC_URL          - ARC endpoint (default: https://testnet.arcade.gorillapool.io)
#   ARC_API_KEY      - ARC API key
#
# Run:
#   bundle exec rspec spec/e2e/pay_gateway_e2e_spec.rb

require_relative "e2e_helper"
require_relative "e2e_logger"

RSpec.describe "PayGateway e2e", :e2e do
  let(:client_wif) { ENV.fetch("CLIENT_WIF") { skip "CLIENT_WIF not set" } }
  let(:payee_script_hex) { ENV.fetch("PAYEE_SCRIPT") { skip "PAYEE_SCRIPT not set" } }
  let(:arc_url) { ENV.fetch("ARC_URL", "https://testnet.arcade.gorillapool.io") }
  let(:base_url) { "http://localhost:#{@port}" }

  before(:all) do
    ENV["ARC_URL"] ||= "https://testnet.arcade.gorillapool.io"
    ENV["PAYEE_SCRIPT"] ||= "76a914#{"00" * 20}88ac"

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
      log_path = E2ELogger.start_log("pay-gateway-e2e")
      E2ELogger.header("PayGateway BSV-pay — BSV Testnet E2E")

      client_key = BSV::Primitives::PrivateKey.from_wif(client_wif)
      E2ELogger.wallets(
        client_addr: client_key.public_key.address(network: :testnet),
        payee_script: payee_script_hex
      )

      E2ELogger.separator

      # Step 1: Client requests protected resource
      E2ELogger.step(1, :client, "Request protected resource")
      uri = URI("#{base_url}/protected")
      E2ELogger.arrow(:client, :server, "GET /protected")

      challenge_response = Net::HTTP.get_response(uri)
      expect(challenge_response.code).to eq("402")

      E2ELogger.arrow(:server, :client, "HTTP/1.1 402 Payment Required")
      challenge = E2EHelper.parse_challenge(challenge_response)
      accept = challenge["accepts"].first
      E2ELogger.result("Payment-Required", "#{challenge_response["payment-required"][0..40]}...")
      E2ELogger.result("Network", accept["network"])
      E2ELogger.result("Amount", "#{accept["amount"]} sats")
      E2ELogger.result("Payee", accept["payTo"][0..20])
      E2ELogger.result("Template", accept.dig("extra", "partialTx") ? "present (Profile B)" : "none")

      E2ELogger.separator

      # Step 2: Client builds payment
      E2ELogger.step(2, :client, "Build payment transaction")

      amount = accept["amount"].to_i
      payee_hex = accept["payTo"]

      if accept.dig("extra", "partialTx")
        template_binary = Base64.strict_decode64(accept["extra"]["partialTx"])
        transaction = BSV::Transaction::Transaction.from_binary(template_binary)
        E2ELogger.result("Source", "Extended extra.partialTx template")
      else
        payee_script = BSV::Script::Script.from_hex(payee_hex)
        transaction = BSV::Transaction::Transaction.new
        transaction.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: amount,
                                 locking_script: payee_script
                               ))
        E2ELogger.result("Source", "Built from payTo + amount")
      end

      provider = BSV::Network::WhatsOnChain.new(network: :testnet)
      wallet = BSV::Wallet::Wallet.new(private_key: client_key, provider: provider)
      wallet.fund_and_sign(transaction, network: :testnet)

      E2ELogger.result("Inputs", transaction.inputs.size.to_s)
      E2ELogger.result("Outputs", transaction.outputs.size.to_s)
      transaction.outputs.each_with_index do |output, idx|
        if output.locking_script.op_return?
          E2ELogger.result("  Output #{idx}", "OP_RETURN x402 binding")
        elsif output.satoshis == amount
          E2ELogger.result("  Output #{idx}", "#{output.satoshis} sats (payment)")
        else
          E2ELogger.result("  Output #{idx}", "#{output.satoshis} sats (change)")
        end
      end

      E2ELogger.separator

      # Step 3: Client submits payment to server
      E2ELogger.step(3, :client, "Submit payment")
      payment_header = E2EHelper.build_payment_signature(challenge, transaction)

      E2ELogger.arrow(:client, :server, "GET /protected")
      E2ELogger.result("Payment-Signature", "#{payment_header[0..40]}...")

      http = Net::HTTP.new(uri.host, uri.port)
      request = Net::HTTP::Get.new(uri)
      request["Payment-Signature"] = payment_header

      E2ELogger.separator

      # Step 4: Server verifies and broadcasts
      E2ELogger.step(4, :server, "Verify payment and broadcast via ARC")
      E2ELogger.result("Verify", "payToSig HMAC, payment output, OP_RETURN binding")
      E2ELogger.arrow(:server, :arc, "POST /v1/tx (X-WaitFor: SEEN_ON_NETWORK)")

      response = http.request(request)

      if response.code == "200"
        E2ELogger.arrow(:arc, :server, "HTTP/1.1 200 OK")

        if response["payment-response"]
          receipt = JSON.parse(Base64.strict_decode64(response["payment-response"]))
          E2ELogger.tx("Settlement tx", receipt["transaction"])
          E2ELogger.result("ARC status", "accepted")
        end

        E2ELogger.separator

        E2ELogger.arrow(:server, :client, "HTTP/1.1 200 OK")
        body = JSON.parse(response.body)
        E2ELogger.result("Content-Type", response["content-type"])
        E2ELogger.result("Body", body.to_json[0..60])

        E2ELogger.success("Payment accepted — content served")
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
        expect(receipt["network"]).to eq("bsv:mainnet")
        expect(receipt["transaction"]).not_to be_empty
      end
    ensure
      E2ELogger.finish_log
      E2ELogger.emit "  Log: #{log_path}" if log_path
    end
  end

  describe "error cases" do
    it "returns 402 when Payment-Signature is missing" do
      uri = URI("#{base_url}/protected")
      response = Net::HTTP.get_response(uri)
      expect(response.code).to eq("402")
    end

    it "returns error when payment is insufficient" do
      uri = URI("#{base_url}/protected")
      challenge_response = Net::HTTP.get_response(uri)
      challenge = E2EHelper.parse_challenge(challenge_response)

      payee_script = BSV::Script::Script.from_hex(challenge["accepts"].first["payTo"])
      transaction = BSV::Transaction::Transaction.new
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: 0,
                               locking_script: payee_script
                             ))

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
