# frozen_string_literal: true

RSpec.describe "JSON Canonicalization (RFC 8785)" do
  it "sorts hash keys alphabetically" do
    expect({ z: 1, a: 2 }.to_json_c14n).to eq('{"a":2,"z":1}')
  end

  it "produces no whitespace" do
    result = { key: "value", nested: { a: 1 } }.to_json_c14n
    expect(result).not_to match(/\s/)
  end

  it "handles nested structures with sorted keys" do
    input = { b: { d: 1, c: 2 }, a: [3, { f: 4, e: 5 }] }
    expect(input.to_json_c14n).to eq('{"a":[3,{"e":5,"f":4}],"b":{"c":2,"d":1}}')
  end

  it "is used by Challenge#to_canonical_json" do
    challenge = X402::Challenge.new(version: 1, scheme: "bsv-tx-v1", amount_sats: 50)
    json = challenge.to_canonical_json
    expect(json).to include('"amount_sats":50')
    expect(json).to include('"scheme":"bsv-tx-v1"')
    # Keys should be sorted — amount before scheme
    expect(json.index("amount_sats")).to be < json.index("scheme")
  end
end
