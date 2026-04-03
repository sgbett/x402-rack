# frozen_string_literal: true

module X402
  # Background thread that broadcasts transactions to ARC with exponential
  # backoff retry. Uses Ruby stdlib Thread + Queue (zero dependencies).
  #
  # Any object responding to +#enqueue(tx_binary)+ satisfies the pluggable
  # worker interface expected by PayGateway's async settlement path.
  #
  # @example With failure callback
  #   worker = X402::SettlementWorker.new(
  #     arc_client: arc,
  #     on_failure: ->(tx_binary, error) { logger.error("Settlement failed: #{error}") }
  #   )
  class SettlementWorker
    ACCEPTABLE_STATUSES = %w[SEEN_ON_NETWORK ANNOUNCED_TO_NETWORK MINED].freeze
    DEFAULT_MAX_QUEUE = 1000

    attr_reader :max_retries, :max_queue

    # @param arc_client [#broadcast] ARC client for broadcasting
    # @param max_retries [Integer] retry attempts before giving up (default 5)
    # @param max_queue [Integer] maximum queued transactions (default 1000).
    #   Raises +X402::VerificationError+ (503) when full.
    # @param on_failure [#call, nil] callback invoked with +(tx_binary, error)+
    #   when all retries are exhausted. Default nil (silent drop).
    def initialize(arc_client:, max_retries: 5, max_queue: DEFAULT_MAX_QUEUE, on_failure: nil)
      @arc_client = arc_client
      @max_retries = max_retries
      @max_queue = max_queue
      @on_failure = on_failure
      @queue = Queue.new
      @thread = nil
      @mutex = Mutex.new
    end

    # Enqueue a transaction for background broadcast.
    #
    # @param tx_binary [String] raw transaction bytes
    # @raise [X402::VerificationError] with status 503 when queue is full
    def enqueue(tx_binary)
      raise VerificationError.new("settlement queue full — try again later", status: 503) if @queue.size >= @max_queue

      ensure_thread_running
      @queue.push(tx_binary)
    end

    def stop
      thread_to_join = nil
      @mutex.synchronize do
        return unless @thread&.alive?

        @queue.push(:shutdown)
        thread_to_join = @thread
        @thread = nil
      end
      thread_to_join&.join
    end

    private

    def ensure_thread_running
      @mutex.synchronize do
        @thread = nil unless @thread&.alive?
        @thread ||= Thread.new { process_loop }
      end
    end

    def process_loop
      loop do
        item = @queue.pop
        break if item == :shutdown

        broadcast_with_retry(item)
      end
    end

    def broadcast_with_retry(tx_binary, attempt = 0)
      result = @arc_client.broadcast(tx_binary, wait_for: "SEEN_ON_NETWORK")
      return if ACCEPTABLE_STATUSES.include?(result.tx_status)

      if attempt >= @max_retries
        notify_failure(tx_binary, "status #{result.tx_status} after #{attempt + 1} attempts")
        return
      end

      sleep(2**attempt)
      broadcast_with_retry(tx_binary, attempt + 1)
    rescue StandardError => e
      if attempt >= @max_retries
        notify_failure(tx_binary, e)
        return
      end

      sleep(2**attempt)
      broadcast_with_retry(tx_binary, attempt + 1)
    end

    def notify_failure(tx_binary, error)
      @on_failure&.call(tx_binary, error)
    rescue StandardError
      # Never let callback failures crash the worker thread
    end
  end
end
