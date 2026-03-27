# frozen_string_literal: true

require "net/http"
require "json"
require "base64"
require "bsv-sdk"
require "x402"
require "x402/bsv"

module E2EHelper
  # Start a Rack server in a background thread for testing.
  # Returns the thread and the port.
  def self.start_server(config_ru:, port: 9393)
    require "rack"
    require "webrick"

    app, = Rack::Builder.parse_file(config_ru)

    server = WEBrick::HTTPServer.new(
      Port: port,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: []
    )
    server.mount "/", Rack::Handler::WEBrick, app

    thread = Thread.new { server.start }

    # Wait for server to be ready
    10.times do
      Net::HTTP.get(URI("http://localhost:#{port}/"))
      break
    rescue Errno::ECONNREFUSED
      sleep 0.1
    end

    [server, thread, port]
  end

  def self.stop_server(server, thread)
    server&.shutdown
    thread&.join(2)
  end

  # Parse a Payment-Required challenge from a 402 response
  def self.parse_challenge(response)
    header = response["payment-required"]
    raise "No Payment-Required header in response" unless header

    JSON.parse(Base64.strict_decode64(header))
  end

  # Build a Payment-Signature payload from a signed transaction
  def self.build_payment_signature(challenge, transaction)
    accept = challenge["accepts"].first

    payload = {
      "x402Version" => 2,
      "accepted" => accept,
      "payload" => {
        "rawtx" => transaction.to_binary.unpack1("H*"),
        "txid" => transaction.txid_hex
      }
    }

    Base64.strict_encode64(JSON.generate(payload))
  end
end
