# frozen_string_literal: true

require "json"
require "rack"

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
  #     c.server_wif = ENV["SERVER_WIF"]
  #     c.enable_status_endpoint
  #     # c.status_endpoint_path  = "/_x402/status"          # default
  #     # c.status_endpoint_token = ENV["X402_STATUS_TOKEN"] # optional
  #   end
  #
  # Auth model:
  # - Default (no token): localhost-only (REMOTE_ADDR must be 127.0.0.1 or ::1)
  # - Token set: localhost still allowed; non-localhost requires
  #   +Authorization: Bearer <token>+
  #
  # Format selection: +?format=json+ or +Accept: application/json+ → JSON;
  # otherwise HTML.
  #
  # Phase 1 scope: identity public key, identity address, gem version.
  # Balance, UTXOs, ARC reachability and other live signals are deferred
  # to later phases — see issue #108.
  class StatusEndpoint
    LOCALHOST_ADDRS = %w[127.0.0.1 ::1].freeze
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
      remote_addr = env["REMOTE_ADDR"].to_s
      return true if LOCALHOST_ADDRS.include?(remote_addr)

      token = config.status_endpoint_token
      return false if token.nil? || token.empty?

      header = env["HTTP_AUTHORIZATION"].to_s
      return false unless header.start_with?("Bearer ")

      presented = header.sub(/\ABearer\s+/, "")
      Rack::Utils.secure_compare(token, presented)
    end

    def json_requested?(env)
      query = env["QUERY_STRING"].to_s
      return true if query.split("&").include?("format=json")

      env["HTTP_ACCEPT"].to_s.include?("application/json")
    end

    def build_data
      {
        x402_rack_version: X402::VERSION,
        identity: identity_data
      }
    end

    def identity_data
      key = identity_private_key
      if key
        {
          public_key: key.public_key.to_hex,
          address: key.public_key.address,
          address_note: ADDRESS_NOTE
        }
      else
        {
          public_key: nil,
          address: nil,
          address_note: "server_wif is not configured — no identity available."
        }
      end
    end

    def identity_private_key
      wif = config.server_wif
      return if wif.nil? || wif.empty?

      ::BSV::Primitives::PrivateKey.from_wif(wif)
    rescue StandardError
      nil
    end

    def json_response(data)
      [200, { "content-type" => "application/json" }, [JSON.generate(data)]]
    end

    def html_response(data)
      [200, { "content-type" => "text/html; charset=utf-8" }, [render_html(data)]]
    end

    def forbidden
      body = JSON.generate(error: "forbidden")
      [403, { "content-type" => "application/json" }, [body]]
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
