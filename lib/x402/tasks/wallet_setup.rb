# frozen_string_literal: true

require "fileutils"
require "io/console"
require_relative "../wallet"
require_relative "../errors"

module X402
  module Tasks
    # Interactive wallet setup task — backing implementation for
    # +rake x402:wallet:setup+.
    #
    # Behaviour:
    #   - Checks BSV_WALLET_DIR/wallet.key (default ~/.bsv-wallet/wallet.key)
    #   - If exists: prints identity key, reports dir, exits cleanly. Never
    #     overwrites. Set FORCE=1 to replace an existing wallet.
    #   - If absent: offers [1] create new / [2] restore from WIF / [3] cancel
    #   - New wallets get a random PrivateKey. WIF written with mode 0600.
    #   - Parent directory created with mode 0700.
    #
    # Designed for dependency injection in tests: pass custom +stdin+,
    # +stdout+, +dir+, and +random_wif+ to the constructor.
    class WalletSetup
      FORCE_ENV_VAR = "FORCE"

      # @param stdin [IO] input stream (default +$stdin+)
      # @param stdout [IO] output stream (default +$stdout+)
      # @param dir [String, nil] wallet directory override (default
      #   +BSV_WALLET_DIR+ env or +~/.bsv-wallet+)
      # @param random_wif [#call, nil] lambda returning a WIF string.
      #   Injectable for tests. Defaults to
      #   +BSV::Primitives::PrivateKey.generate.to_wif+.
      def initialize(stdin: $stdin, stdout: $stdout, dir: nil, random_wif: nil)
        require "bsv-sdk"
        @stdin = stdin
        @stdout = stdout
        @dir = dir || ENV.fetch("BSV_WALLET_DIR", X402::Wallet::DEFAULT_DIR)
        @random_wif = random_wif || -> { ::BSV::Primitives::PrivateKey.generate.to_wif }
      end

      def run
        ensure_dir!
        if File.exist?(key_path)
          handle_existing
        else
          handle_fresh
        end
      end

      private

      attr_reader :stdin, :stdout, :dir

      def key_path
        File.join(dir, X402::Wallet::KEY_FILENAME)
      end

      def ensure_dir!
        FileUtils.mkdir_p(dir, mode: 0o700)
      rescue StandardError => e
        abort "[x402] could not create wallet dir #{dir}: #{e.message}"
      end

      def handle_existing
        if ENV[FORCE_ENV_VAR] == "1"
          stdout.puts "[x402] FORCE=1 set — overwriting existing wallet at #{key_path}"
          write_new_wallet
          return
        end

        identity_key = read_identity_key(key_path)
        stdout.puts "[x402] Wallet already exists at #{key_path}"
        stdout.puts "[x402]   identity key: #{identity_key}" if identity_key
        stdout.puts "[x402]   storage dir:  #{dir}"
        stdout.puts "[x402] Leaving wallet intact. Use FORCE=1 to overwrite (destructive)."
      end

      def handle_fresh
        stdout.puts "[x402] No wallet found at #{key_path}"
        stdout.puts
        stdout.puts "  [1] Create new wallet (random key)"
        stdout.puts "  [2] Restore existing wallet from WIF"
        stdout.puts "  [3] Cancel"
        stdout.print "Choice [1]: "

        choice = stdin.gets&.strip
        choice = "1" if choice.nil? || choice.empty?

        case choice
        when "1" then write_new_wallet
        when "2" then restore_from_wif
        when "3" then stdout.puts "[x402] cancelled — no wallet written"
        else
          abort "[x402] invalid choice #{choice.inspect}"
        end
      end

      def write_new_wallet
        wif = @random_wif.call
        write_wif(wif)
        announce_wallet(wif, action: "Created new wallet")
      end

      def restore_from_wif
        stdout.print "Paste WIF (input hidden): "
        wif = read_hidden_input.to_s.strip
        abort "[x402] no WIF entered — aborting" if wif.empty?

        validate_wif!(wif)
        write_wif(wif)
        announce_wallet(wif, action: "Restored wallet")
      end

      def read_hidden_input
        # Fall back to plain gets when stdin is not a TTY (e.g. StringIO
        # in tests). IO::console#noecho is only defined on real TTYs.
        if stdin.respond_to?(:noecho) && stdin.respond_to?(:tty?) && stdin.tty?
          result = stdin.noecho(&:gets)
          stdout.puts
          result
        else
          stdin.gets
        end
      end

      def validate_wif!(wif)
        ::BSV::Primitives::PrivateKey.from_wif(wif)
      rescue StandardError => e
        abort "[x402] invalid WIF: #{e.message}"
      end

      def write_wif(wif)
        File.open(key_path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write("#{wif}\n")
        end
      end

      def announce_wallet(wif, action:)
        identity_key = read_identity_key_from_wif(wif)
        stdout.puts "[x402] #{action} at #{key_path}"
        stdout.puts "[x402]   identity key: #{identity_key}" if identity_key
        stdout.puts "[x402]   storage dir:  #{dir}"
        stdout.puts "[x402]   file mode:    0600"
      end

      def read_identity_key(path)
        wif = File.read(path).strip
        read_identity_key_from_wif(wif)
      rescue StandardError
        nil
      end

      def read_identity_key_from_wif(wif)
        key = ::BSV::Primitives::PrivateKey.from_wif(wif)
        key.public_key.to_hex
      rescue StandardError
        nil
      end
    end
  end
end
