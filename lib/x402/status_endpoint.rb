# frozen_string_literal: true

require "json"
require "rack"
require "bsv-sdk"
require "bsv-wallet"

module X402
  # Read-only HTTP status endpoint for the x402-rack middleware.
  #
  # Renders a minimal page exposing wallet identity (public key + base
  # P2PKH address) and the gem version. Designed to provide passive
  # observability during development and ops without ever mutating
  # state or making external network calls.
  #
  # @example Enable in configuration
  #   X402.configure do |c|
  #     c.wallet = my_wallet  # any BRC-100 compatible wallet
  #     c.enable_status_endpoint
  #     # c.status_endpoint_token = ENV["X402_STATUS_TOKEN"] # explicit (recommended in prod)
  #     # c.status_endpoint_path  = "/_x402/status"          # default
  #   end
  #
  # Auth model:
  # - Bearer-token only. Every request requires
  #   +Authorization: Bearer <token>+ — there is no localhost
  #   bypass and no network-trust heuristic.
  # - If +status_endpoint_token+ is unset, the configuration auto-generates
  #   one at +validate!+ time and logs it once at startup so it can be
  #   copied into a curl command. Production deployments should set the
  #   token explicitly via an environment variable.
  #
  # Format selection: +?format=json+ or +Accept: application/json+ → JSON;
  # otherwise HTML.
  #
  # Phase 1 scope: identity public key, identity address, gem version.
  # Balance, UTXOs, ARC reachability and other live signals are deferred
  # to later phases — see issue #108.
  class StatusEndpoint
    ADDRESS_NOTE = "Identity address — used for BRC-42 derivation. " \
                   "Not the per-payment receive address. Payments are " \
                   "settled to per-payment derived addresses."

    def initialize(config)
      @config = config
    end

    # @param env [Hash] Rack environment
    # @return [Array(Integer, Hash, Array)] Rack response triple
    def call(env)
      return forbidden unless authorised?(env)

      data = build_data
      if json_requested?(env)
        json_response(data)
      else
        html_response(data)
      end
    end

    private

    attr_reader :config

    def authorised?(env)
      token = config.status_endpoint_token
      return false if token.nil? || token.to_s.empty?

      header = env["HTTP_AUTHORIZATION"].to_s
      match = header.match(/\ABearer\s+(.+)\z/i)
      return false unless match

      Rack::Utils.secure_compare(token, match[1])
    end

    def json_requested?(env)
      return true if Rack::Request.new(env).params["format"] == "json"

      env["HTTP_ACCEPT"].to_s.include?("application/json")
    end

    def build_data
      {
        x402_rack_version: X402::VERSION,
        identity: identity_data
      }
    end

    # Resolves the server's identity (public key + address) via the
    # shared wallet's +get_public_key(identity_key: true)+ interface.
    #
    # Returns a hash with +:public_key+, +:address+, and +:address_note+.
    # Degrades gracefully when no wallet is configured or the wallet
    # raises an error — never crashes the endpoint.
    #
    # @return [Hash]
    def identity_data
      wallet = config.shared_wallet
      return identity_missing unless wallet

      result = wallet.get_public_key({ identity_key: true })
      hex = result.is_a?(Hash) ? (result[:public_key] || result["publicKey"]) : result
      address = ::BSV::Primitives::PublicKey.from_hex(hex).address

      {
        public_key: hex,
        address: address,
        address_note: ADDRESS_NOTE
      }
    rescue StandardError
      identity_invalid
    end

    def identity_missing
      {
        public_key: nil,
        address: nil,
        address_note: "No wallet configured — identity not available."
      }
    end

    def identity_invalid
      {
        public_key: nil,
        address: nil,
        address_note: "Wallet is configured but identity key could not be resolved — check wallet configuration."
      }
    end

    def response_headers(content_type)
      {
        "content-type" => content_type,
        "cache-control" => "no-store",
        "vary" => "Accept, Authorization"
      }
    end

    def json_response(data)
      [200, response_headers("application/json"), [JSON.generate(data)]]
    end

    def html_response(data)
      [200, response_headers("text/html; charset=utf-8"), [render_html(data)]]
    end

    def forbidden
      body = JSON.generate(error: "forbidden")
      [403, response_headers("application/json"), [body]]
    end

    def render_html(data)
      identity = data[:identity]
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>x402-rack status</title>
        <style>
        body { font-family: system-ui, -apple-system, sans-serif; max-width: 720px; margin: 2em auto; padding: 0 1em; color: #222; }
        h1 { font-size: 1.4em; border-bottom: 1px solid #ccc; padding-bottom: 0.3em; }
        h2 { font-size: 1.1em; margin-top: 1.5em; }
        dl { display: grid; grid-template-columns: max-content 1fr; gap: 0.4em 1em; }
        dt { font-weight: 600; color: #555; }
        dd { margin: 0; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; word-break: break-all; }
        .note { color: #666; font-size: 0.9em; margin-top: 0.5em; font-style: italic; }
        footer { margin-top: 2em; color: #999; font-size: 0.85em; border-top: 1px solid #eee; padding-top: 0.5em; }
        </style>
        </head>
        <body>
        <h1>x402-rack status</h1>

        <h2>Identity</h2>
        <dl>
        <dt>Public key</dt><dd>#{html_escape(identity[:public_key] || "(not configured)")}</dd>
        <dt>Address</dt><dd>#{html_escape(identity[:address] || "(not configured)")}</dd>
        </dl>
        <p class="note">#{html_escape(identity[:address_note])}</p>

        <footer>x402-rack v#{html_escape(data[:x402_rack_version])}</footer>
        </body>
        </html>
      HTML
    end

    def html_escape(str)
      Rack::Utils.escape_html(str.to_s)
    end
  end
end
