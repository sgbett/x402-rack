# frozen_string_literal: true

# Minimal Rack server for e2e testing.
#
# Usage:
#   rackup spec/e2e/config.ru -p 9292
#
# Environment variables:
#   ARC_URL       - ARC endpoint (default: https://arc.taal.com)
#   ARC_API_KEY   - ARC API key (optional)
#   PAYEE_SCRIPT  - payee locking script hex (required)

require "bundler/setup"
require "x402"
require "x402/bsv"

arc_url = ENV.fetch("ARC_URL", "https://arc.taal.com")
arc_api_key = ENV.fetch("ARC_API_KEY", nil)
payee_script = ENV.fetch("PAYEE_SCRIPT") { raise "PAYEE_SCRIPT env var is required" }

# Minimal ARC client for e2e
arc_client = Object.new
arc_client.define_singleton_method(:broadcast) do |transaction|
  require "net/http"
  require "json"

  uri = URI("#{arc_url}/v1/tx")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"

  request = Net::HTTP::Post.new(uri)
  request["Content-Type"] = "application/octet-stream"
  request["X-WaitFor"] = "SEEN_ON_NETWORK"
  request["Authorization"] = "Bearer #{arc_api_key}" if arc_api_key
  request.body = transaction.to_binary

  response = http.request(request)
  raise "ARC broadcast failed: #{response.code} #{response.body}" unless response.code.to_i == 200

  JSON.parse(response.body)
end

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
