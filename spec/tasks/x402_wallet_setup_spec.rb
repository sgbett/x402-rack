# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require "stringio"
require "bsv-sdk"
require "x402/tasks/wallet_setup"

RSpec.describe X402::Tasks::WalletSetup do
  let(:tmpdir) { Dir.mktmpdir("x402-wallet-setup-spec") }
  let(:key_path) { File.join(tmpdir, "wallet.key") }
  let(:stdout) { StringIO.new }
  let(:fixed_wif) { BSV::Primitives::PrivateKey.generate.to_wif }
  let(:random_wif) { -> { fixed_wif } }

  around do |example|
    original_force = ENV.fetch("FORCE", nil)
    ENV.delete("FORCE")
    example.run
    ENV["FORCE"] = original_force if original_force
  end

  after { FileUtils.rm_rf(tmpdir) }

  def build_setup(choice: "1", wif_input: nil)
    stdin = StringIO.new
    stdin.puts(choice)
    stdin.puts(wif_input) if wif_input
    stdin.rewind
    described_class.new(stdin: stdin, stdout: stdout, dir: tmpdir, random_wif: random_wif)
  end

  describe "fresh install (no existing wallet)" do
    it "creates a new wallet when the user chooses [1]" do
      setup = build_setup(choice: "1")
      setup.run

      expect(File.exist?(key_path)).to be true
      expect(File.read(key_path).strip).to eq(fixed_wif)
    end

    it "writes the key file with mode 0600" do
      setup = build_setup(choice: "1")
      setup.run

      mode = File.stat(key_path).mode & 0o777
      expect(mode).to eq(0o600)
    end

    it "creates the parent directory with mode 0700 if missing" do
      nested = File.join(tmpdir, "deep", "nested")
      stdin = StringIO.new("1\n")
      setup = described_class.new(stdin: stdin, stdout: stdout, dir: nested, random_wif: random_wif)
      setup.run

      expect(Dir.exist?(nested)).to be true
      mode = File.stat(nested).mode & 0o777
      expect(mode).to eq(0o700)
    end

    it "prints the identity public key after creation" do
      setup = build_setup(choice: "1")
      setup.run

      expected_pubkey = BSV::Primitives::PrivateKey.from_wif(fixed_wif).public_key.to_hex
      expect(stdout.string).to include("Created new wallet")
      expect(stdout.string).to include(expected_pubkey)
      expect(stdout.string).to include(tmpdir)
    end

    it "restores from a provided WIF when the user chooses [2]" do
      user_wif = BSV::Primitives::PrivateKey.generate.to_wif
      stdin = StringIO.new
      # Without a TTY, noecho falls through to gets; feed both the choice
      # and the WIF.
      stdin.puts("2")
      stdin.puts(user_wif)
      stdin.rewind
      setup = described_class.new(stdin: stdin, stdout: stdout, dir: tmpdir, random_wif: random_wif)
      setup.run

      expect(File.read(key_path).strip).to eq(user_wif)
      expected_pubkey = BSV::Primitives::PrivateKey.from_wif(user_wif).public_key.to_hex
      expect(stdout.string).to include("Restored wallet")
      expect(stdout.string).to include(expected_pubkey)
    end

    it "cancels cleanly when the user chooses [3]" do
      setup = build_setup(choice: "3")
      setup.run

      expect(File.exist?(key_path)).to be false
      expect(stdout.string).to include("cancelled")
    end

    it "defaults to create-new when the user presses Enter" do
      setup = build_setup(choice: "")
      setup.run

      expect(File.exist?(key_path)).to be true
      expect(File.read(key_path).strip).to eq(fixed_wif)
    end
  end

  describe "existing wallet" do
    before do
      File.write(key_path, "#{fixed_wif}\n")
      File.chmod(0o600, key_path)
    end

    it "never overwrites an existing wallet by default" do
      before_mtime = File.mtime(key_path)
      setup = build_setup(choice: "1")
      setup.run

      expect(File.mtime(key_path)).to eq(before_mtime)
      expect(File.read(key_path).strip).to eq(fixed_wif)
    end

    it "reports the existing wallet's identity key" do
      setup = build_setup(choice: "1")
      setup.run

      expected_pubkey = BSV::Primitives::PrivateKey.from_wif(fixed_wif).public_key.to_hex
      expect(stdout.string).to include("Wallet already exists")
      expect(stdout.string).to include(expected_pubkey)
      expect(stdout.string).to include("FORCE=1 to overwrite")
    end

    it "does not prompt (no interactive input consumed)" do
      stdin = StringIO.new # intentionally empty
      setup = described_class.new(stdin: stdin, stdout: stdout, dir: tmpdir, random_wif: random_wif)
      expect { setup.run }.not_to raise_error
    end

    context "with FORCE=1" do
      it "overwrites the existing wallet with a new random key" do
        new_wif = BSV::Primitives::PrivateKey.generate.to_wif
        ENV["FORCE"] = "1"
        setup = described_class.new(
          stdin: StringIO.new, stdout: stdout, dir: tmpdir, random_wif: -> { new_wif }
        )
        setup.run

        expect(File.read(key_path).strip).to eq(new_wif)
        expect(stdout.string).to include("FORCE=1 set — overwriting")
      end
    end
  end
end
