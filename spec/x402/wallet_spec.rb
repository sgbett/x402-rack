# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "bsv-wallet"
require "x402/wallet"

RSpec.describe X402::Wallet do
  let(:tmpdir) { Dir.mktmpdir("x402-wallet-spec") }
  let(:key_path) { File.join(tmpdir, "wallet.key") }
  let(:sample_wif) { BSV::Primitives::PrivateKey.generate.to_wif }

  around do |example|
    original = ENV.fetch("SERVER_WIF", nil)
    ENV.delete("SERVER_WIF")
    example.run
    ENV["SERVER_WIF"] = original if original
  end

  after do
    FileUtils.rm_rf(tmpdir)
  end

  describe ".key_path" do
    it "returns <dir>/wallet.key for an explicit dir" do
      expect(described_class.key_path(dir: "/var/lib/wallets")).to eq("/var/lib/wallets/wallet.key")
    end

    it "respects BSV_WALLET_DIR env var when dir omitted" do
      ENV["BSV_WALLET_DIR"] = tmpdir
      expect(described_class.key_path).to eq(File.join(tmpdir, "wallet.key"))
    ensure
      ENV.delete("BSV_WALLET_DIR")
    end
  end

  describe ".load" do
    context "SERVER_WIF env var wins over on-disk wallet.key" do
      it "uses SERVER_WIF when both are present" do
        File.write(key_path, "file_wif_should_be_ignored\n")
        disk_wif = sample_wif
        File.write(key_path, disk_wif)

        env_wif = BSV::Primitives::PrivateKey.generate.to_wif
        ENV["SERVER_WIF"] = env_wif

        wallet = described_class.load(dir: tmpdir)
        env_pubkey = BSV::Primitives::PrivateKey.from_wif(env_wif).public_key.to_hex
        expect(wallet.key_deriver.identity_key).to eq(env_pubkey)
      end
    end

    context "with only the on-disk wallet.key" do
      it "returns a Client built from the file" do
        File.write(key_path, "#{sample_wif}\n")
        wallet = described_class.load(dir: tmpdir)

        expected_key = BSV::Primitives::PrivateKey.from_wif(sample_wif).public_key.to_hex
        expect(wallet).to be_a(BSV::Wallet::Client)
        expect(wallet.key_deriver.identity_key).to eq(expected_key)
      end

      it "uses a Store::File pointed at the same directory" do
        File.write(key_path, sample_wif)
        wallet = described_class.load(dir: tmpdir)
        expect(wallet.storage).to be_a(BSV::Wallet::Store::File)
        expect(wallet.storage.dir).to eq(tmpdir)
      end
    end

    context "with only SERVER_WIF (no file)" do
      it "returns a Client built from the env var" do
        ENV["SERVER_WIF"] = sample_wif
        wallet = described_class.load(dir: tmpdir)
        expected_key = BSV::Primitives::PrivateKey.from_wif(sample_wif).public_key.to_hex
        expect(wallet.key_deriver.identity_key).to eq(expected_key)
      end
    end

    context "with neither source configured" do
      it "raises ConfigurationError with a hint to run the setup task" do
        expect { described_class.load(dir: tmpdir) }
          .to raise_error(X402::ConfigurationError, /SERVER_WIF.*rake x402:wallet:setup/)
      end
    end

    context "trailing newline in wallet.key" do
      it "strips whitespace when parsing the WIF" do
        File.write(key_path, "#{sample_wif}\n\n")
        expect { described_class.load(dir: tmpdir) }.not_to raise_error
      end
    end
  end
end
