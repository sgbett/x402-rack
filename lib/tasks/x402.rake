# frozen_string_literal: true

require_relative "../x402/tasks/wallet_setup"

namespace :x402 do
  namespace :wallet do
    desc "Create or restore the server wallet (never overwrites existing)"
    task :setup do
      X402::Tasks::WalletSetup.new.run
    end
  end
end
