# frozen_string_literal: true

# Relay-mode Rack server for e2e testing.
#
# Uses a remote wallet (via operator_wallet_url) instead of a local WIF.
# The auto-enable path activates PayGateway and BRC121Gateway automatically.
#
# Usage:
#   OPERATOR_WALLET_URL=http://localhost:3000 rackup spec/e2e/relay_config.ru -p 9393
#
# Environment variables:
#   OPERATOR_WALLET_URL - remote wallet endpoint (required)
#   ARC_URL             - ARC endpoint (default: testnet via ARC.default)
#   ARC_API_KEY         - ARC API key

require "bundler/setup"
require "x402"

X402.reset_configuration!
X402.configure do |config|
  config.domain = "localhost"
  config.network = "bsv:testnet"
  config.operator_wallet_url = ENV.fetch("OPERATOR_WALLET_URL") { raise "OPERATOR_WALLET_URL env var is required" }
  config.arc_url = ENV.fetch("ARC_URL", nil)
  config.arc_api_key = ENV.fetch("ARC_API_KEY", nil)

  config.enable :pay_gateway, binding_mode: :permissive
  config.protect method: "GET", path: "/protected", amount_sats: 2000
end

app = lambda do |env|
  case env["PATH_INFO"]
  when "/protected"
    [200, { "content-type" => "application/json" }, ['{"secret":"you paid for this"}']]
  else
    [200, { "content-type" => "text/plain" }, ["OK"]]
  end
end

use X402::Middleware
run app
