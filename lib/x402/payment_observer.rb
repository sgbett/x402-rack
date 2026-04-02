# frozen_string_literal: true

require "base64"
require "json"
require "bsv-sdk"

module X402
  # Rack middleware that silently observes voluntary payment headers and
  # enqueues them for settlement. Never gates access — requests always
  # pass through regardless of payment presence or validity.
  #
  # Only enqueues transactions that contain at least one output paying
  # the configured payee — the observer is not an open relay.
  #
  # Sits alongside +X402::Middleware+ in the Rack stack:
  #
  #   use X402::PaymentObserver,
  #     worker: settlement_worker,
  #     payee_locking_script_hex: "76a914...88ac"
  #   use X402::Middleware
  #   run MyApp
  #
  # Any object responding to +#enqueue(tx_binary)+ satisfies the worker
  # interface (e.g. +X402::SettlementWorker+, a Sidekiq job, etc.).
  class PaymentObserver
    DEFAULT_PROOF_HEADERS = %w[Payment-Signature].freeze

    # @param app [#call] next Rack app in the stack
    # @param worker [#enqueue] settlement worker for background broadcast
    # @param payee_locking_script_hex [String] payee script hex — only txs
    #   with at least one output paying this script are enqueued
    # @param proof_headers [Array<String>] HTTP header names to watch for payments
    # @param on_payment [#call, nil] optional callback invoked with the raw tx
    #   binary after successful enqueue, for application-level tracking
    def initialize(app, worker:, payee_locking_script_hex:,
                   proof_headers: DEFAULT_PROOF_HEADERS, on_payment: nil)
      @app = app
      @worker = worker
      @payee_script = ::BSV::Script::Script.from_hex(payee_locking_script_hex)
      @proof_headers = proof_headers
      @on_payment = on_payment
    end

    def call(env)
      observe_payment(env)
      @app.call(env)
    end

    private

    def observe_payment(env)
      @proof_headers.each do |header_name|
        rack_key = "HTTP_#{header_name.upcase.tr("-", "_")}"
        value = env[rack_key]
        next if value.nil? || value.empty?

        tx_binary = extract_and_validate(value)
        next unless tx_binary

        enqueue_payment(tx_binary)
        break
      end
    end

    def enqueue_payment(tx_binary)
      @worker.enqueue(tx_binary)
      @on_payment&.call(tx_binary)
    rescue StandardError
      # Never let enqueue/callback failures break the request pass-through
    end

    def extract_and_validate(proof_payload)
      json = Base64.strict_decode64(proof_payload)
      payload = JSON.parse(json)
      rawtx_hex = payload.dig("payload", "rawtx")
      return unless rawtx_hex

      tx_binary = [rawtx_hex].pack("H*")
      tx = ::BSV::Transaction::Transaction.from_binary(tx_binary)
      return unless pays_us?(tx)

      tx_binary
    rescue StandardError
      nil
    end

    def pays_us?(transaction)
      transaction.outputs.any? do |output|
        output.locking_script.to_hex == @payee_script.to_hex
      end
    end
  end
end
