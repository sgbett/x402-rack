# frozen_string_literal: true

require "rack"
require "json"
require "base64"
require "x402/bsv"

RSpec.describe X402::BSV::ProofGateway do
  let(:payee_hex) { "76a914#{"aa" * 20}88ac" }
  let(:payee_script) { BSV::Script::Script.from_hex(payee_hex) }
  let(:nonce_txid) { "bb" * 32 }
  let(:nonce) do
    { txid: nonce_txid, vout: 0, satoshis: 1, locking_script_hex: "76a914#{"cc" * 20}88ac" }
  end
  let(:nonce_provider) { ->(_req) { nonce } }
  let(:route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 50) }

  let(:mock_arc) do
    arc = Object.new
    def arc.status(_txid)
      { "status" => "SEEN_ON_NETWORK" }
    end
    arc
  end

  let(:gateway) do
    described_class.new(
      nonce_provider: nonce_provider,
      arc_client: mock_arc,
      payee_locking_script_hex: payee_hex
    )
  end

  before do
    X402.reset_configuration!
    X402.configuration.domain = "api.example.com"
    X402.configuration.payee_locking_script_hex = payee_hex
  end

  after { X402.reset_configuration! }

  def mock_request(method: "GET", path: "/premium", query: "")
    url = query.empty? ? path : "#{path}?#{query}"
    Rack::Request.new(Rack::MockRequest.env_for(url, method: method))
  end

  describe "#challenge_headers" do
    let(:request) { mock_request }
    let(:headers) { gateway.challenge_headers(request, route) }

    it "returns a hash with X402-Challenge key" do
      expect(headers).to have_key("X402-Challenge")
    end

    it "contains a valid base64url-encoded challenge" do
      json = X402::Base64Url.decode(headers["X402-Challenge"])
      challenge = JSON.parse(json)
      expect(challenge["version"]).to eq(1)
      expect(challenge["scheme"]).to eq("bsv-tx-v1")
    end

    it "includes nonce UTXO details" do
      json = X402::Base64Url.decode(headers["X402-Challenge"])
      challenge = JSON.parse(json)
      expect(challenge["nonce_txid"]).to eq(nonce_txid)
      expect(challenge["nonce_vout"]).to eq(0)
    end

    it "includes request binding" do
      json = X402::Base64Url.decode(headers["X402-Challenge"])
      challenge = JSON.parse(json)
      expect(challenge["method"]).to eq("GET")
      expect(challenge["path"]).to eq("/premium")
      expect(challenge["domain"]).to eq("api.example.com")
    end

    it "includes payment details" do
      json = X402::Base64Url.decode(headers["X402-Challenge"])
      challenge = JSON.parse(json)
      expect(challenge["amount_sats"]).to eq(50)
      expect(challenge["payee_locking_script_hex"]).to eq(payee_hex)
    end

    it "sets an expiry in the future" do
      json = X402::Base64Url.decode(headers["X402-Challenge"])
      challenge = JSON.parse(json)
      expect(challenge["expires_at"]).to be > Time.now.to_i
    end
  end

  describe "#proof_header_names" do
    it "returns X402-Proof" do
      expect(gateway.proof_header_names).to eq(["X402-Proof"])
    end
  end

  describe "#settle!" do
    # Build a valid proof: get challenge, construct tx, encode proof
    def build_valid_proof(request)
      headers = gateway.challenge_headers(request, route)
      challenge_header = headers["X402-Challenge"]
      challenge = X402::Challenge.from_header(challenge_header)

      # Build tx spending the nonce + paying the payee
      transaction = BSV::Transaction::Transaction.new
      nonce_txid_bytes = [nonce_txid].pack("H*").reverse
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: nonce_txid_bytes,
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: 50,
                               locking_script: payee_script
                             ))

      proof_data = {
        challenge_sha256: challenge.sha256_hex,
        payment: {
          rawtx_b64: Base64.strict_encode64(transaction.to_binary),
          txid: transaction.txid_hex
        }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(proof_data))

      # Return both so the request env can be set up
      [challenge_header, proof_header]
    end

    it "returns SettlementResult on valid proof" do
      request = mock_request
      challenge_header, proof_header = build_valid_proof(request)
      request.env["HTTP_X402_CHALLENGE"] = challenge_header

      result = gateway.settle!("X402-Proof", proof_header, request, route)
      expect(result).to be_a(X402::SettlementResult)
      expect(result.network).to eq("bsv:mainnet")
      expect(result.txid).not_to be_nil
    end

    it "raises on tampered challenge hash" do
      request = mock_request
      challenge_header, = build_valid_proof(request)
      request.env["HTTP_X402_CHALLENGE"] = challenge_header

      bad_proof = {
        challenge_sha256: "00" * 32,
        payment: { rawtx_b64: "dHg=", txid: "aa" * 32 }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(bad_proof))

      expect { gateway.settle!("X402-Proof", proof_header, request, route) }
        .to raise_error(X402::VerificationError, /challenge hash/)
    end

    it "raises when nonce UTXO is not spent in transaction" do
      request = mock_request
      challenge_header, = build_valid_proof(request)
      request.env["HTTP_X402_CHALLENGE"] = challenge_header

      # Tx with wrong input (not the nonce)
      transaction = BSV::Transaction::Transaction.new
      wrong_txid_bytes = ["ee" * 32].pack("H*")
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: wrong_txid_bytes,
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: 50,
                               locking_script: payee_script
                             ))

      challenge = X402::Challenge.from_header(challenge_header)
      bad_proof = {
        challenge_sha256: challenge.sha256_hex,
        payment: {
          rawtx_b64: Base64.strict_encode64(transaction.to_binary),
          txid: transaction.txid_hex
        }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(bad_proof))

      expect { gateway.settle!("X402-Proof", proof_header, request, route) }
        .to raise_error(X402::VerificationError, /nonce/)
    end

    it "raises on insufficient payment" do
      request = mock_request
      challenge_header, = build_valid_proof(request)
      request.env["HTTP_X402_CHALLENGE"] = challenge_header
      challenge = X402::Challenge.from_header(challenge_header)

      # Tx with correct nonce but insufficient payment
      transaction = BSV::Transaction::Transaction.new
      nonce_txid_bytes = [nonce_txid].pack("H*").reverse
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: nonce_txid_bytes,
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))
      transaction.add_output(BSV::Transaction::TransactionOutput.new(
                               satoshis: 1,
                               locking_script: payee_script
                             ))

      bad_proof = {
        challenge_sha256: challenge.sha256_hex,
        payment: {
          rawtx_b64: Base64.strict_encode64(transaction.to_binary),
          txid: transaction.txid_hex
        }
      }
      proof_header = X402::Base64Url.encode(JSON.generate(bad_proof))

      expect { gateway.settle!("X402-Proof", proof_header, request, route) }
        .to raise_error(X402::VerificationError) { |e| expect(e.status).to eq(402) }
    end

    it "raises when mempool check fails" do
      failing_arc = Object.new
      def failing_arc.status(_txid)
        raise "connection refused"
      end

      failing_gw = described_class.new(
        nonce_provider: nonce_provider,
        arc_client: failing_arc,
        payee_locking_script_hex: payee_hex
      )

      request = mock_request

      # Need to rebuild proof against the failing gateway's challenge
      headers = failing_gw.challenge_headers(request, route)
      challenge_header2 = headers["X402-Challenge"]
      challenge2 = X402::Challenge.from_header(challenge_header2)

      transaction = BSV::Transaction::Transaction.new
      nonce_txid_bytes = [nonce_txid].pack("H*").reverse
      transaction.add_input(BSV::Transaction::TransactionInput.new(
                              prev_tx_id: nonce_txid_bytes,
                              prev_tx_out_index: 0,
                              unlocking_script: BSV::Script::Script.new("\x00".b)
                            ))
      transaction.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 50, locking_script: payee_script))

      proof_data = {
        challenge_sha256: challenge2.sha256_hex,
        payment: { rawtx_b64: Base64.strict_encode64(transaction.to_binary), txid: transaction.txid_hex }
      }
      proof_header2 = X402::Base64Url.encode(JSON.generate(proof_data))
      request.env["HTTP_X402_CHALLENGE"] = challenge_header2

      expect { failing_gw.settle!("X402-Proof", proof_header2, request, route) }
        .to raise_error(X402::VerificationError, /mempool/)
    end

    it "raises when X402-Challenge header is missing" do
      request = mock_request
      proof_data = { challenge_sha256: "aa" * 32, payment: { rawtx_b64: "dHg=", txid: "bb" * 32 } }
      proof_header = X402::Base64Url.encode(JSON.generate(proof_data))

      expect { gateway.settle!("X402-Proof", proof_header, request, route) }
        .to raise_error(X402::VerificationError, /missing X402-Challenge/)
    end
  end

  context "Profile B (with nonce_key)" do
    let(:nonce_key) { BSV::Primitives::PrivateKey.generate }
    let(:nonce_h160) { nonce_key.public_key.hash160.unpack1("H*") }
    let(:nonce_locking_script) { "76a914#{nonce_h160}88ac" }
    let(:profile_b_nonce) do
      { txid: nonce_txid, vout: 0, satoshis: 1, locking_script_hex: nonce_locking_script }
    end
    let(:profile_b_provider) { ->(_req) { profile_b_nonce } }

    let(:profile_b_gateway) do
      described_class.new(
        nonce_provider: profile_b_provider,
        arc_client: mock_arc,
        nonce_key: nonce_key,
        payee_locking_script_hex: payee_hex
      )
    end

    describe "#challenge_headers" do
      it "includes partial_tx_b64 in the challenge" do
        request = mock_request
        headers = profile_b_gateway.challenge_headers(request, route)
        json = X402::Base64Url.decode(headers["X402-Challenge"])
        challenge = JSON.parse(json)
        expect(challenge["partial_tx_b64"]).not_to be_nil
      end

      it "produces a template with a signed nonce input at index 0" do
        request = mock_request
        headers = profile_b_gateway.challenge_headers(request, route)
        json = X402::Base64Url.decode(headers["X402-Challenge"])
        challenge = JSON.parse(json)

        template = BSV::Transaction::Transaction.from_binary(
          Base64.strict_decode64(challenge["partial_tx_b64"])
        )
        expect(template.inputs.size).to eq(1)
        expect(template.inputs[0].unlocking_script.to_hex).not_to be_empty
        expect(template.outputs.size).to eq(2)
        expect(template.outputs[0].satoshis).to eq(50)
      end

      it "sha256_hex is the same with and without partial_tx_b64" do
        request = mock_request

        # Profile B challenge
        b_headers = profile_b_gateway.challenge_headers(request, route)
        b_challenge = X402::Challenge.from_header(b_headers["X402-Challenge"])

        # Profile A challenge (same params, no nonce_key)
        a_gw = described_class.new(
          nonce_provider: profile_b_provider,
          arc_client: mock_arc,
          payee_locking_script_hex: payee_hex
        )
        a_headers = a_gw.challenge_headers(request, route)
        a_challenge = X402::Challenge.from_header(a_headers["X402-Challenge"])

        # Hashes should be equal (partial_tx_b64 excluded from canonical form)
        expect(b_challenge.sha256_hex).to eq(a_challenge.sha256_hex)
      end
    end

    describe "full Profile B roundtrip" do
      it "challenge → extend template → prove → settle" do
        request = mock_request

        # Step 1: Get challenge
        headers = profile_b_gateway.challenge_headers(request, route)
        challenge_header = headers["X402-Challenge"]
        challenge_json = X402::Base64Url.decode(challenge_header)
        challenge_data = JSON.parse(challenge_json)
        challenge = X402::Challenge.from_header(challenge_header)

        # Step 2: Decode and extend template
        template = BSV::Transaction::Transaction.from_binary(
          Base64.strict_decode64(challenge_data["partial_tx_b64"])
        )

        # Client adds a funding input
        funding_txid_bytes = ["dd" * 32].pack("H*")
        template.add_input(BSV::Transaction::TransactionInput.new(
                             prev_tx_id: funding_txid_bytes,
                             prev_tx_out_index: 0,
                             unlocking_script: BSV::Script::Script.new("\x00".b)
                           ))

        # Step 3: Encode as proof
        proof_data = {
          challenge_sha256: challenge.sha256_hex,
          payment: {
            rawtx_b64: Base64.strict_encode64(template.to_binary),
            txid: template.txid_hex
          }
        }
        proof_header = X402::Base64Url.encode(JSON.generate(proof_data))

        # Step 4: Settle
        request.env["HTTP_X402_CHALLENGE"] = challenge_header
        result = profile_b_gateway.settle!("X402-Proof", proof_header, request, route)

        expect(result).to be_a(X402::SettlementResult)
        expect(result.txid).to eq(template.txid_hex)
      end

      it "rejects proof when nonce signed by wrong key" do
        wrong_key = BSV::Primitives::PrivateKey.generate
        wrong_h160 = wrong_key.public_key.hash160.unpack1("H*")
        wrong_nonce = { txid: nonce_txid, vout: 0, satoshis: 1,
                        locking_script_hex: "76a914#{wrong_h160}88ac" }

        # Gateway with wrong nonce key — nonce UTXO doesn't match
        expect do
          wrong_gw = described_class.new(
            nonce_provider: ->(_req) { wrong_nonce },
            arc_client: mock_arc,
            nonce_key: nonce_key, # key doesn't match wrong_nonce
            payee_locking_script_hex: payee_hex
          )
          wrong_gw.challenge_headers(mock_request, route)
        end.to raise_error(X402::ConfigurationError, /nonce_key/)
      end

      it "rejects proof with nonce at index 1 instead of index 0" do
        request = mock_request
        headers = profile_b_gateway.challenge_headers(request, route)
        challenge_header = headers["X402-Challenge"]
        challenge = X402::Challenge.from_header(challenge_header)

        # Build tx with a fake input at index 0 and nonce at index 1
        tx = BSV::Transaction::Transaction.new
        # Index 0: fake input
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_tx_id: ["ee" * 32].pack("H*"),
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.new("\x00".b)
                     ))
        # Index 1: real nonce
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_tx_id: [nonce_txid].pack("H*").reverse,
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.new("\x00".b)
                     ))
        tx.add_output(BSV::Transaction::TransactionOutput.new(
                        satoshis: 50, locking_script: payee_script
                      ))

        proof_data = {
          challenge_sha256: challenge.sha256_hex,
          payment: { rawtx_b64: Base64.strict_encode64(tx.to_binary), txid: tx.txid_hex }
        }
        proof_header = X402::Base64Url.encode(JSON.generate(proof_data))
        request.env["HTTP_X402_CHALLENGE"] = challenge_header

        expect { profile_b_gateway.settle!("X402-Proof", proof_header, request, route) }
          .to raise_error(X402::VerificationError, /nonce UTXO must be at input index 0/)
      end

      it "rejects proof with fake unlocking script containing server pubkey" do
        request = mock_request
        headers = profile_b_gateway.challenge_headers(request, route)
        challenge_header = headers["X402-Challenge"]
        challenge = X402::Challenge.from_header(challenge_header)

        # Build tx with nonce at index 0 but a spoofed unlocking script
        nonce_txid_bytes = [nonce_txid].pack("H*").reverse
        server_pubkey_hex = nonce_key.public_key.to_hex
        # Craft fake P2PKH unlock: <push 71 bytes of garbage sig> <push 33 bytes of server pubkey>
        fake_sig = "00" * 71
        fake_unlock_hex = "47#{fake_sig}21#{server_pubkey_hex}"
        fake_unlock = BSV::Script::Script.from_hex(fake_unlock_hex)

        tx = BSV::Transaction::Transaction.new
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_tx_id: nonce_txid_bytes,
                       prev_tx_out_index: 0,
                       unlocking_script: fake_unlock
                     ))
        tx.add_output(BSV::Transaction::TransactionOutput.new(
                        satoshis: 50, locking_script: payee_script
                      ))

        proof_data = {
          challenge_sha256: challenge.sha256_hex,
          payment: { rawtx_b64: Base64.strict_encode64(tx.to_binary), txid: tx.txid_hex }
        }
        proof_header = X402::Base64Url.encode(JSON.generate(proof_data))
        request.env["HTTP_X402_CHALLENGE"] = challenge_header

        expect { profile_b_gateway.settle!("X402-Proof", proof_header, request, route) }
          .to raise_error(X402::VerificationError, /nonce.*failed/)
      end
    end
  end
end
