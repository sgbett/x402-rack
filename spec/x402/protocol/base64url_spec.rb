# frozen_string_literal: true

require "securerandom"
require_relative "../../../lib/x402/protocol/base64url"

RSpec.describe X402::Base64Url do
  describe ".encode" do
    it "encodes data without padding" do
      encoded = described_class.encode("hello world")
      expect(encoded).not_to include("=")
      expect(encoded).to eq("aGVsbG8gd29ybGQ")
    end

    it "uses URL-safe characters" do
      # Binary data that would produce + and / in standard base64
      data = [0xFF, 0xEF, 0xBF].pack("C*")
      encoded = described_class.encode(data)
      expect(encoded).not_to include("+")
      expect(encoded).not_to include("/")
    end
  end

  describe ".decode" do
    it "decodes base64url data" do
      decoded = described_class.decode("aGVsbG8gd29ybGQ")
      expect(decoded).to eq("hello world")
    end

    it "roundtrips arbitrary data" do
      data = SecureRandom.random_bytes(32)
      expect(described_class.decode(described_class.encode(data))).to eq(data)
    end

    it "raises X402::Error for invalid input" do
      expect { described_class.decode("!!!invalid!!!") }.to raise_error(X402::Error, /invalid base64url/)
    end
  end
end
