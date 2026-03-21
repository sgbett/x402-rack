# frozen_string_literal: true

RSpec.describe X402 do
  it "has a version number" do
    expect(X402::VERSION).not_to be_nil
  end

  describe ".configure" do
    after { described_class.reset_configuration! }

    it "yields a configuration object" do
      described_class.configure do |c|
        c.domain = "example.com"
        c.payee_locking_script_hex = "76a914#{"aa" * 20}88ac"
        c.nonce_provider = -> {}
        c.protect(method: "GET", path: "/", amount_sats: 1)
        expect(c).to be_a(X402::Configuration)
      end
    end

    it "validates configuration" do
      expect do
        described_class.configure { |c| c.domain = "example.com" }
      end.to raise_error(X402::ConfigurationError)
    end
  end

  describe ".reset_configuration!" do
    it "resets to a fresh configuration" do
      described_class.configuration.domain = "old.example.com"
      described_class.reset_configuration!
      expect(described_class.configuration.domain).to be_nil
    end
  end
end
