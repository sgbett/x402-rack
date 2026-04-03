# frozen_string_literal: true

require "monitor"

module X402
  module BSV
    # Pluggable txid deduplication store for PayGateway settlement.
    #
    # Prevents the same transaction from being accepted twice.
    # Duck-type contract — any backend must implement:
    #   seen?(txid)  — returns true if txid was already recorded
    #   record!(txid) — records the txid as seen
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

        # Returns true if the txid has already been recorded and hasn't expired.
        def seen?(txid)
          @monitor.synchronize do
            entry = @entries[txid]
            entry && !expired?(entry)
          end
        end

        # Records the txid as seen. Purges expired entries first.
        def record!(txid)
          @monitor.synchronize do
            purge_expired!
            @entries[txid] = monotonic_now
            # Evict oldest if over capacity
            evict_oldest! if @entries.size > @max_size
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
