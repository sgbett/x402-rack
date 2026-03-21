# frozen_string_literal: true

require "rack"
require "json"

RSpec.describe X402::Middleware do
  let(:inner_app) { ->(_env) { [200, { "content-type" => "text/plain" }, ["OK"]] } }
  let(:app) { described_class.new(inner_app) }

  let(:payee_script_hex) { "76a914#{"aa" * 20}88ac" }
  let(:nonce_txid) { "bb" * 32 }

  let(:nonce) do
    {
      txid: nonce_txid,
      vout: 0,
      satoshis: 1000,
      locking_script_hex: "76a914#{"cc" * 20}88ac"
    }
  end

  before do
    X402.reset_configuration!
    X402.configure do |c|
      c.domain = "api.example.com"
      c.payee_locking_script_hex = payee_script_hex
      c.nonce_provider = ->(_req) { nonce }
      c.protect(method: "GET", path: "/premium", amount_sats: 50)
    end
  end

  after { X402.reset_configuration! }

  describe "unprotected routes" do
    it "passes through to the app" do
      env = Rack::MockRequest.env_for("/free", method: "GET")
      status, _headers, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "protected route without proof" do
    it "returns 402 with X402-Challenge header" do
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      status, headers, body = app.call(env)

      expect(status).to eq(402)
      expect(headers["x402-challenge"]).not_to be_nil

      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to eq("Payment Required")
      expect(parsed["challenge"]["version"]).to eq(1)
    end
  end

  describe "protected route with valid proof" do
    it "forwards to the app" do
      # First, get the challenge
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      _, challenge_headers, = app.call(env)
      challenge_header = challenge_headers["x402-challenge"]

      # Build a valid transaction
      challenge = X402::Challenge.from_header(challenge_header)
      payee_script = BSV::Script::Script.from_hex(payee_script_hex)

      tx = BSV::Transaction::Transaction.new
      nonce_txid_bytes = [nonce_txid].pack("H*").reverse
      tx.add_input(BSV::Transaction::TransactionInput.new(
                     prev_tx_id: nonce_txid_bytes,
                     prev_tx_out_index: 0,
                     unlocking_script: BSV::Script::Script.new("\x00".b)
                   ))
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: 50,
                      locking_script: payee_script
                    ))

      proof_data = {
        challenge_sha256: challenge.sha256_hex,
        payment: {
          rawtx_b64: Base64.strict_encode64(tx.to_binary),
          txid: tx.txid_hex
        }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(proof_data))

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X402_PROOF"] = proof_header
      env["HTTP_X402_CHALLENGE"] = challenge_header

      status, _headers, body = app.call(env)
      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end
  end

  describe "protected route with invalid proof" do
    it "returns 400 for malformed proof" do
      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X402_PROOF"] = "not-valid-base64url!!!"
      env["HTTP_X402_CHALLENGE"] = "also-invalid!!!"

      status, _headers, body = app.call(env)
      expect(status).to eq(400)
      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to match(/invalid/)
    end

    it "returns 400 when challenge header is missing" do
      proof_data = { challenge_sha256: "abc", payment: { rawtx_b64: "dHg", txid: "aa" * 32 } }
      proof_header = X402::Base64Url.encode(JSON.generate(proof_data))

      env = Rack::MockRequest.env_for("/premium", method: "GET")
      env["HTTP_X402_PROOF"] = proof_header

      status, _headers, body = app.call(env)
      expect(status).to eq(400)
      parsed = JSON.parse(body.first)
      expect(parsed["error"]).to match(/missing X402-Challenge/)
    end
  end
end
