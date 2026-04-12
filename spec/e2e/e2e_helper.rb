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
    require "rackup"

    server = Rackup::Server.new(
      config: config_ru,
      Port: port,
      server: :webrick,
      Logger: WEBrick::Log.new(File::NULL),
      AccessLog: [],
      Silent: true
    )

    thread = Thread.new { server.start }

    # Wait for server to be ready
    20.times do
      Net::HTTP.get(URI("http://localhost:#{port}/"))
      break
    rescue Errno::ECONNREFUSED
      sleep 0.2
    end

    [server, thread, port]
  end

  def self.stop_server(server, thread)
    server&.server&.shutdown if server.respond_to?(:server)
    thread&.join(2)
  end

  # Parse a Payment-Required challenge from a 402 response
  def self.parse_challenge(response)
    header = response["payment-required"]
    raise "No Payment-Required header in response" unless header

    JSON.parse(Base64.strict_decode64(header))
  end

  # Build a Payment-Signature payload from a signed transaction.
  # Includes BEEF (BRC-62) when the transaction has source data available,
  # enabling wallet internalisation on the server side.
  def self.build_payment_signature(challenge, transaction)
    accept = challenge["accepts"].first

    payload_inner = {
      "rawtx" => transaction.to_binary.unpack1("H*"),
      "txid" => transaction.txid_hex
    }

    # Include BEEF when possible — BRC-100 wallets need it for internalisation
    begin
      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(transaction)
      payload_inner["beef"] = Base64.strict_encode64(beef.to_atomic_binary(transaction.txid))
    rescue StandardError
      # Source transactions unavailable — send without BEEF
    end

    payload = {
      "x402Version" => 2,
      "accepted" => accept,
      "payload" => payload_inner
    }

    Base64.strict_encode64(JSON.generate(payload))
  end
end
