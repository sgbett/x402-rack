# frozen_string_literal: true

require "monitor"

module X402
  module BSV
    # Pluggable txid deduplication store for PayGateway settlement.
    #
    # Prevents the same transaction from being accepted twice.
    # Duck-type contract — any backend must implement:
    #   record_if_unseen!(txid) — atomically records the txid and returns true
    #     if it was not already seen. Returns false if already recorded.
    module TxidStore
      # In-memory backend suitable for development and single-process deployments.
      # Thread-safe via Monitor. Entries expire after +ttl+ seconds.
      #
      # NOTE: This store provides no deduplication across OS processes.
      # Production multi-process deployments should use a shared backend.
      class Memory
        DEFAULT_TTL = 600
        DEFAULT_MAX_SIZE = 10_000

        # @param ttl [Integer] seconds before a seen txid expires (default 600)
        # @param max_size [Integer] cap on stored txids (default 10_000)
        def initialize(ttl: DEFAULT_TTL, max_size: DEFAULT_MAX_SIZE)
          @entries = {}
          @monitor = Monitor.new
          @ttl = ttl
          @max_size = max_size
        end

        # Atomically checks and records a txid.
        # Returns true if the txid was new (now recorded).
        # Returns false if already seen (duplicate).
        def record_if_unseen!(txid)
          @monitor.synchronize do
            purge_expired!

            entry = @entries[txid]
            return false if entry && !expired?(entry)

            @entries[txid] = monotonic_now
            evict_oldest! if @entries.size > @max_size
            true
          end
        end

        private

        def purge_expired!
          @entries.delete_if { |_, recorded_at| (monotonic_now - recorded_at) > @ttl }
        end

        def evict_oldest!
          oldest_key = @entries.min_by { |_, recorded_at| recorded_at }&.first
          @entries.delete(oldest_key) if oldest_key
        end

        def expired?(recorded_at)
          (monotonic_now - recorded_at) > @ttl
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
