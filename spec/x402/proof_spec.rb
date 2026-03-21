# frozen_string_literal: true

RSpec.describe X402::Proof do
  describe ".from_header" do
    let(:proof_data) do
      {
        challenge_sha256: "abc123",
        payment: {
          rawtx_b64: "dHhkYXRh",
          txid: "deadbeef" * 8
        }
      }
    end

    let(:header) { X402::Base64Url.encode(JSON.generate(proof_data)) }

    it "decodes a valid proof header" do
      proof = described_class.from_header(header)
      expect(proof.challenge_sha256).to eq("abc123")
      expect(proof.txid).to eq("deadbeef" * 8)
      expect(proof.rawtx_b64).to eq("dHhkYXRh")
    end

    it "raises on invalid base64url" do
      expect { described_class.from_header("!!!") }.to raise_error(X402::Error)
    end

    it "raises on invalid JSON" do
      header = X402::Base64Url.encode("not json")
      expect { described_class.from_header(header) }.to raise_error(X402::Error, /invalid proof JSON/)
    end
  end
end
