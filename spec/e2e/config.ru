# frozen_string_literal: true

# Minimal Rack server for e2e testing.
#
# Usage:
#   rackup spec/e2e/config.ru -p 9292
#
# Environment variables:
#   ARC_URL       - ARC endpoint (default: https://testnet.arcade.gorillapool.io)
#   ARC_API_KEY   - ARC API key
#   PAYEE_SCRIPT  - payee locking script hex (required)

require "bundler/setup"
require "x402"
require "x402/bsv"

arc_url = ENV.fetch("ARC_URL", "https://testnet.arcade.gorillapool.io")
arc_api_key = ENV.fetch("ARC_API_KEY", nil)
payee_script = ENV.fetch("PAYEE_SCRIPT") { raise "PAYEE_SCRIPT env var is required" }

arc_client = BSV::Network::ARC.new(arc_url, api_key: arc_api_key)

X402.reset_configuration!
X402.configure do |config|
  config.domain = "localhost"
  config.payee_locking_script_hex = payee_script

  config.gateways = [
    X402::BSV::PayGateway.new(
      arc_client: arc_client,
      payee_locking_script_hex: payee_script
    )
  ]

  config.protect method: "GET", path: "/protected", amount_sats: 500
end

# Simple app that routes based on path
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
