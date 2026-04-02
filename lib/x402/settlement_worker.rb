# frozen_string_literal: true

module X402
  # Background thread that broadcasts transactions to ARC with exponential
  # backoff retry. Uses Ruby stdlib Thread + Queue (zero dependencies).
  #
  # Any object responding to +#enqueue(tx_binary)+ satisfies the pluggable
  # worker interface expected by PayGateway's async settlement path.
  class SettlementWorker
    ACCEPTABLE_STATUSES = %w[SEEN_ON_NETWORK ANNOUNCED_TO_NETWORK MINED].freeze

    attr_reader :max_retries

    def initialize(arc_client:, max_retries: 5)
      @arc_client = arc_client
      @max_retries = max_retries
      @queue = Queue.new
      @thread = nil
      @mutex = Mutex.new
    end

    def enqueue(tx_binary)
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
      return if attempt >= @max_retries

      sleep(2**attempt)
      broadcast_with_retry(tx_binary, attempt + 1)
    rescue StandardError
      return if attempt >= @max_retries

      sleep(2**attempt)
      broadcast_with_retry(tx_binary, attempt + 1)
    end
  end
end
