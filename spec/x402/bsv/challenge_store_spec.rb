# frozen_string_literal: true

require "x402/bsv"
require "x402/protocol/challenge"

RSpec.describe X402::BSV::ChallengeStore::Memory do
  let(:challenge) do
    X402::Challenge.new(
      version: 1, scheme: "bsv-tx-v1", domain: "api.example.com",
      method: "GET", path: "/premium", query: "",
      req_headers_sha256: "a" * 64, req_body_sha256: "b" * 64,
      amount_sats: 50, payee_locking_script_hex: "76a914#{"aa" * 20}88ac",
      nonce_txid: "cc" * 32, nonce_vout: 0, nonce_satoshis: 1,
      nonce_locking_script_hex: "76a914#{"cc" * 20}88ac",
      expires_at: Time.now.to_i + 300
    )
  end
  let(:hash) { challenge.sha256_hex }

  it "stores and returns a challenge by hash" do
    store = described_class.new
    store.store!(hash, challenge)
    expect(store.lookup(hash)).to eq(challenge)
  end

  it "returns nil for unknown hashes" do
    expect(described_class.new.lookup("deadbeef")).to be_nil
  end

  it "consumes a challenge exactly once" do
    store = described_class.new
    store.store!(hash, challenge)

    expect(store.consume!(hash)).to be true
    expect(store.consume!(hash)).to be false
    expect(store.lookup(hash)).to be_nil
  end

  it "lookup returns nil after consume" do
    store = described_class.new
    store.store!(hash, challenge)
    store.consume!(hash)
    expect(store.lookup(hash)).to be_nil
  end

  it "expires entries after the TTL" do
    store = described_class.new(ttl: 0)
    store.store!(hash, challenge)
    sleep 0.01
    expect(store.lookup(hash)).to be_nil
  end

  it "raises StoreFullError when max_issued is reached" do
    store = described_class.new(max_issued: 1)
    store.store!(hash, challenge)

    expect { store.store!("other", challenge) }
      .to raise_error(X402::BSV::ChallengeStore::StoreFullError)
  end
end
