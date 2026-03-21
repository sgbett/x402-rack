# frozen_string_literal: true

require "rack"

RSpec.describe X402::Verifier do
  # Build a minimal valid BSV transaction that:
  # - Spends the nonce UTXO as an input
  # - Has an output paying to the payee locking script
  let(:payee_script_hex) { "76a914#{"aa" * 20}88ac" }
  let(:nonce_txid) { "bb" * 32 }
  let(:nonce_vout) { 0 }
  let(:amount_sats) { 50 }

  let(:payee_script) { BSV::Script::Script.from_hex(payee_script_hex) }

  let(:tx) do
    t = BSV::Transaction::Transaction.new
    # Input spending the nonce UTXO
    # prev_tx_id is wire byte order (natural hash) — nonce_txid is display order (reversed)
    nonce_txid_bytes = [nonce_txid].pack("H*").reverse
    input = BSV::Transaction::TransactionInput.new(
      prev_tx_id: nonce_txid_bytes,
      prev_tx_out_index: nonce_vout,
      unlocking_script: BSV::Script::Script.new("\x00".b)
    )
    t.add_input(input)

    output = BSV::Transaction::TransactionOutput.new(
      satoshis: amount_sats,
      locking_script: payee_script
    )
    t.add_output(output)
    t
  end

  let(:rawtx_b64) { Base64.strict_encode64(tx.to_binary) }

  let(:nonce) do
    {
      txid: nonce_txid,
      vout: nonce_vout,
      satoshis: 1000,
      locking_script_hex: "76a914#{"cc" * 20}88ac"
    }
  end

  let(:config) do
    c = X402::Configuration.new
    c.domain = "api.example.com"
    c.payee_locking_script_hex = payee_script_hex
    c.nonce_provider = ->(_req) { nonce }
    c.protect(method: "GET", path: "/v1/premium", amount_sats: amount_sats)
    c
  end

  let(:route) { config.routes.first }

  let(:rack_request) do
    env = Rack::MockRequest.env_for("/v1/premium", method: "GET")
    Rack::Request.new(env)
  end

  let(:challenge) do
    X402::Challenge.build(rack_request, route: route, config: config)
  end

  let(:proof) do
    X402::Proof.new(
      challenge_sha256: challenge.sha256_hex,
      payment: { rawtx_b64: rawtx_b64, txid: tx.txid_hex }
    )
  end

  describe ".verify!" do
    it "succeeds with valid proof and challenge" do
      result = described_class.verify!(
        proof, challenge: challenge, rack_request: rack_request,
               route: route, config: config
      )
      expect(result).to be_a(BSV::Transaction::Transaction)
    end

    it "fails on unsupported version" do
      bad_challenge = X402::Challenge.new(challenge.to_h.merge(version: 99))
      expect do
        described_class.verify!(proof, challenge: bad_challenge, rack_request: rack_request,
                                       route: route, config: config)
      end.to raise_error(X402::VerificationError, /unsupported version/)
    end

    it "fails on unsupported scheme" do
      bad_challenge = X402::Challenge.new(challenge.to_h.merge(scheme: "unknown"))
      expect do
        described_class.verify!(proof, challenge: bad_challenge, rack_request: rack_request,
                                       route: route, config: config)
      end.to raise_error(X402::VerificationError, /unsupported scheme/)
    end

    it "fails on challenge hash mismatch" do
      bad_proof = X402::Proof.new(
        challenge_sha256: "0000000000000000000000000000000000000000000000000000000000000000",
        payment: proof.payment
      )
      expect do
        described_class.verify!(bad_proof, challenge: challenge, rack_request: rack_request,
                                           route: route, config: config)
      end.to raise_error(X402::VerificationError, /challenge hash mismatch/)
    end

    it "fails on request method mismatch" do
      post_request = Rack::Request.new(
        Rack::MockRequest.env_for("/v1/premium", method: "POST")
      )
      expect do
        described_class.verify!(proof, challenge: challenge, rack_request: post_request,
                                       route: route, config: config)
      end.to raise_error(X402::VerificationError, /request method mismatch/)
    end

    it "fails on expired challenge with status 402" do
      expired = X402::Challenge.new(challenge.to_h.merge(expires_at: Time.now.to_i - 1))
      # Rebuild proof with correct hash for the expired challenge
      expired_proof = X402::Proof.new(
        challenge_sha256: expired.sha256_hex,
        payment: proof.payment
      )
      expect do
        described_class.verify!(expired_proof, challenge: expired, rack_request: rack_request,
                                               route: route, config: config)
      end.to raise_error(X402::VerificationError) { |e|
        expect(e.status).to eq(402)
        expect(e.reason).to match(/expired/)
      }
    end

    it "fails on txid mismatch" do
      bad_proof = X402::Proof.new(
        challenge_sha256: challenge.sha256_hex,
        payment: { rawtx_b64: rawtx_b64, txid: "ff" * 32 }
      )
      expect do
        described_class.verify!(bad_proof, challenge: challenge, rack_request: rack_request,
                                           route: route, config: config)
      end.to raise_error(X402::VerificationError, /txid mismatch/)
    end

    it "fails when nonce UTXO not spent" do
      # Build a tx that doesn't spend the nonce
      t = BSV::Transaction::Transaction.new
      other_txid = ["cc" * 32].pack("H*").reverse
      input = BSV::Transaction::TransactionInput.new(
        prev_tx_id: other_txid,
        prev_tx_out_index: 0,
        unlocking_script: BSV::Script::Script.new("\x00".b)
      )
      t.add_input(input)
      t.add_output(BSV::Transaction::TransactionOutput.new(
                     satoshis: amount_sats,
                     locking_script: payee_script
                   ))

      bad_proof = X402::Proof.new(
        challenge_sha256: challenge.sha256_hex,
        payment: { rawtx_b64: Base64.strict_encode64(t.to_binary), txid: t.txid_hex }
      )
      expect do
        described_class.verify!(bad_proof, challenge: challenge, rack_request: rack_request,
                                           route: route, config: config)
      end.to raise_error(X402::VerificationError, /nonce UTXO not spent/)
    end

    it "fails when payment output is insufficient with status 402" do
      # Build tx with insufficient payment
      t = BSV::Transaction::Transaction.new
      nonce_txid_bytes = [nonce_txid].pack("H*").reverse
      t.add_input(BSV::Transaction::TransactionInput.new(
                    prev_tx_id: nonce_txid_bytes,
                    prev_tx_out_index: nonce_vout,
                    unlocking_script: BSV::Script::Script.new("\x00".b)
                  ))
      t.add_output(BSV::Transaction::TransactionOutput.new(
                     satoshis: amount_sats - 1,
                     locking_script: payee_script
                   ))

      bad_proof = X402::Proof.new(
        challenge_sha256: challenge.sha256_hex,
        payment: { rawtx_b64: Base64.strict_encode64(t.to_binary), txid: t.txid_hex }
      )
      expect do
        described_class.verify!(bad_proof, challenge: challenge, rack_request: rack_request,
                                           route: route, config: config)
      end.to raise_error(X402::VerificationError) { |e|
        expect(e.status).to eq(402)
      }
    end
  end
end
