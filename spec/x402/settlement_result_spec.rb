# frozen_string_literal: true

RSpec.describe X402::SettlementResult do
  it "defaults receipt_headers to empty hash" do
    result = described_class.new
    expect(result.receipt_headers).to eq({})
  end

  it "defaults txid and network to nil" do
    result = described_class.new
    expect(result.txid).to be_nil
    expect(result.network).to be_nil
  end

  it "accepts keyword arguments" do
    result = described_class.new(
      receipt_headers: { "Payment-Response" => "ok" },
      txid: "abc123",
      network: "bsv:mainnet"
    )
    expect(result.receipt_headers).to eq({ "Payment-Response" => "ok" })
    expect(result.txid).to eq("abc123")
    expect(result.network).to eq("bsv:mainnet")
  end
end
