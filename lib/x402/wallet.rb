# frozen_string_literal: true

require "fileutils"

module X402
  # Helpers for loading and persisting the server wallet key.
  #
  # The gem uses +BSV::Wallet::WalletClient+ as the concrete BRC-100 wallet.
  # This module provides a loader that resolves the signing WIF from either
  # the +SERVER_WIF+ environment variable or an on-disk +wallet.key+ file,
  # and constructs a +WalletClient+ with a +FileStore+ pointed at the same
  # directory.
  #
  # See +lib/tasks/x402.rake+ for the interactive +rake x402:wallet:setup+
  # task which creates or restores the on-disk +wallet.key+.
  module Wallet
    DEFAULT_DIR = File.expand_path("~/.bsv-wallet")
    KEY_FILENAME = "wallet.key"

    # Resolve the signing WIF and construct a +BSV::Wallet::WalletClient+.
    #
    # Resolution order (locked per HLR #104):
    #   1. +SERVER_WIF+ environment variable (wins if set)
    #   2. +<dir>/wallet.key+ file (default: +~/.bsv-wallet/wallet.key+,
    #      or +BSV_WALLET_DIR+ if set)
    #   3. Raises +ConfigurationError+ with a hint to run the setup task
    #
    # @param dir [String, nil] override the wallet directory (rarely needed
    #   — prefer +BSV_WALLET_DIR+ env var for process-wide config)
    # @return [BSV::Wallet::WalletClient]
    # @raise [ConfigurationError] if no WIF can be resolved
    def self.load(dir: nil)
      require "bsv-wallet"

      resolved_dir = dir || ENV.fetch("BSV_WALLET_DIR", DEFAULT_DIR)
      wif = resolve_wif(resolved_dir)
      key = ::BSV::Primitives::PrivateKey.from_wif(wif)
      storage = ::BSV::Wallet::FileStore.new(dir: resolved_dir)
      ::BSV::Wallet::WalletClient.new(key, storage: storage)
    end

    # Returns the canonical path to the on-disk wallet key file for the
    # given directory.
    #
    # @param dir [String, nil] optional override
    # @return [String] absolute path
    def self.key_path(dir: nil)
      File.join(dir || ENV.fetch("BSV_WALLET_DIR", DEFAULT_DIR), KEY_FILENAME)
    end

    def self.resolve_wif(dir)
      env_wif = ENV.fetch("SERVER_WIF", nil)
      return env_wif if env_wif.is_a?(String) && !env_wif.empty?

      path = File.join(dir, KEY_FILENAME)
      unless File.exist?(path)
        raise ConfigurationError,
              "No server wallet found. Set SERVER_WIF or run: bundle exec rake x402:wallet:setup"
      end

      File.read(path).strip
    end
    private_class_method :resolve_wif
  end
end
