# frozen_string_literal: true

require "base64"
require "json"
require "bsv-sdk"

module X402
  # Rack middleware that silently observes voluntary payment headers and
  # enqueues them for settlement. Never gates access — requests always
  # pass through regardless of payment presence or validity.
  #
  # Only enqueues transactions that contain at least one recognised output
  # — the observer is not an open relay.
  #
  # == Static payee (simple)
  #
  #   use X402::PaymentObserver,
  #     worker: settlement_worker,
  #     payee_locking_script_hex: "76a914...88ac"
  #
  # == Recogniser (derived addresses / payment channels)
  #
  #   use X402::PaymentObserver,
  #     worker: settlement_worker,
  #     recogniser: session_tracker   # responds to #ours?(locking_script_hex)
  #
  # The recogniser is duck-typed — any object responding to
  # +#ours?(locking_script_hex)+ qualifies. For payment channels with
  # BRC-29 derived addresses, the recogniser tracks which derived addresses
  # belong to active sessions.
  #
  # Any object responding to +#enqueue(tx_binary)+ satisfies the worker
  # interface (e.g. +X402::SettlementWorker+, a Sidekiq job, etc.).
  class PaymentObserver
    DEFAULT_PROOF_HEADERS = %w[Payment-Signature].freeze

    # @param app [#call] next Rack app in the stack
    # @param worker [#enqueue] settlement worker for background broadcast
    # @param payee_locking_script_hex [String, nil] static payee script hex
    # @param recogniser [#ours?, nil] object that recognises derived payment addresses.
    #   Takes precedence over +payee_locking_script_hex+ when both are provided.
    # @param proof_headers [Array<String>] HTTP header names to watch for payments
    # @param on_payment [#call, nil] optional callback invoked with the raw tx
    #   binary after successful enqueue, for application-level tracking
    def initialize(app, worker:, payee_locking_script_hex: nil, recogniser: nil,
                   proof_headers: DEFAULT_PROOF_HEADERS, on_payment: nil)
      @app = app
      @worker = worker
      @recogniser = build_recogniser(recogniser, payee_locking_script_hex)
      @proof_headers = proof_headers
      @on_payment = on_payment
    end

    def call(env)
      observe_payment(env)
      @app.call(env)
    end

    private

    def build_recogniser(recogniser, payee_hex)
      if recogniser
        unless recogniser.respond_to?(:ours?)
          raise ConfigurationError,
                "PaymentObserver recogniser must respond to #ours?(locking_script_hex)"
        end
        return recogniser
      end

      unless payee_hex
        raise ConfigurationError,
              "PaymentObserver requires recogniser: or payee_locking_script_hex:"
      end

      StaticRecogniser.new(payee_hex)
    end

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
      return unless recognised?(tx)

      tx_binary
    rescue StandardError
      nil
    end

    def recognised?(transaction)
      transaction.outputs.any? do |output|
        @recogniser.ours?(output.locking_script.to_hex)
      end
    end

    # Built-in recogniser for a single static payee address.
    # Used when +payee_locking_script_hex+ is provided without a custom recogniser.
    class StaticRecogniser
      def initialize(payee_locking_script_hex)
        @payee_hex = ::BSV::Script::Script.from_hex(payee_locking_script_hex).to_hex
      end

      def ours?(locking_script_hex)
        locking_script_hex == @payee_hex
      end
    end
  end
end
