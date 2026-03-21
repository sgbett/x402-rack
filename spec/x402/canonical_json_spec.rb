# frozen_string_literal: true

RSpec.describe X402::CanonicalJson do
  describe ".encode" do
    it "sorts hash keys alphabetically" do
      result = described_class.encode({ z: 1, a: 2 })
      expect(result).to eq('{"a":2,"z":1}')
    end

    it "produces no whitespace" do
      result = described_class.encode({ key: "value", nested: { a: 1 } })
      expect(result).not_to match(/\s/)
    end

    it "encodes integers without decimals" do
      expect(described_class.encode(42)).to eq("42")
    end

    it "encodes float integers without decimals" do
      expect(described_class.encode(42.0)).to eq("42")
    end

    it "encodes strings with JSON escaping" do
      expect(described_class.encode("hello \"world\"")).to eq('"hello \\"world\\""')
    end

    it "encodes arrays" do
      expect(described_class.encode([1, "two", 3])).to eq('[1,"two",3]')
    end

    it "encodes booleans and null" do
      expect(described_class.encode(true)).to eq("true")
      expect(described_class.encode(false)).to eq("false")
      expect(described_class.encode(nil)).to eq("null")
    end

    it "handles nested structures with sorted keys" do
      input = { b: { d: 1, c: 2 }, a: [3, { f: 4, e: 5 }] }
      result = described_class.encode(input)
      expect(result).to eq('{"a":[3,{"e":5,"f":4}],"b":{"c":2,"d":1}}')
    end
  end
end
