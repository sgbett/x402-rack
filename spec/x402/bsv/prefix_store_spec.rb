# frozen_string_literal: true

require "x402/bsv/prefix_store"

RSpec.describe X402::BSV::PrefixStore::Memory do
  subject(:store) { described_class.new }

  let(:prefix) { "abc123" }

  describe "store, validate, consume" do
    it "tracks a prefix through the full lifecycle" do
      store.store!(prefix)
      expect(store.valid?(prefix)).to be true

      result = store.consume!(prefix)
      expect(result).to be true
      expect(store.valid?(prefix)).to be false
    end
  end

  describe "#consume!" do
    it "returns false on double-consume (replay protection)" do
      store.store!(prefix)
      store.consume!(prefix)
      expect(store.consume!(prefix)).to be false
    end
  end

  describe "#valid?" do
    it "returns false for unknown prefixes" do
      expect(store.valid?("unknown")).to be false
    end
  end

  describe "#consume! with unknown prefix" do
    it "returns false for unknown prefixes" do
      expect(store.consume!("unknown")).to be false
    end
  end

  describe "thread safety" do
    it "handles concurrent consume! without double-success" do
      store.store!(prefix)

      results = Array.new(10) do
        Thread.new { store.consume!(prefix) }
      end.map(&:value)

      expect(results.count(true)).to eq(1)
      expect(results.count(false)).to eq(9)
    end
  end
end
