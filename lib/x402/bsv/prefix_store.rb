# frozen_string_literal: true

require "monitor"

module X402
  module BSV
    # Pluggable replay protection for BRC-105 derivation prefixes.
    #
    # The store tracks prefixes through three states:
    #   nil → :issued → :consumed
    #
    # Duck-type contract — any backend must implement:
    #   store!(prefix)    — records a prefix as issued; raises StoreFullError if at capacity
    #   valid?(prefix)    — non-binding read: true if prefix was issued and not yet consumed.
    #                       Not called in the production settle! path — consume! is used
    #                       directly and must be atomic and self-validating.
    #   consume!(prefix)  — atomically marks prefix as used; returns false if already
    #                       consumed or unknown. Must not rely on a prior valid? call.
    module PrefixStore
      class StoreFullError < X402::Error; end

      # In-memory backend suitable for development and single-process deployments.
      # Thread-safe via Monitor. Entries expire after +ttl+ seconds and the store
      # rejects new prefixes once +max_issued+ unconsumed entries are held.
      #
      # NOTE: This store provides no replay protection across OS processes
      # (e.g. Puma pre-fork, multiple dynos). Production multi-process
      # deployments should use a shared backend (Redis, database).
      class Memory
        DEFAULT_TTL = 300
        DEFAULT_MAX_ISSUED = 10_000

        # @param ttl [Integer] seconds before an issued prefix expires (default 300)
        # @param max_issued [Integer] cap on unconsumed prefixes (default 10_000)
        def initialize(ttl: DEFAULT_TTL, max_issued: DEFAULT_MAX_ISSUED)
          @prefixes = {}
          @monitor = Monitor.new
          @ttl = ttl
          @max_issued = max_issued
        end

        # Record a prefix as issued.
        #
        # @raise [StoreFullError] if max_issued unconsumed prefixes are held
        def store!(prefix)
          @monitor.synchronize do
            purge_expired!
            issued_count = @prefixes.count { |_, v| v[:state] == :issued }
            raise StoreFullError, "prefix store at capacity (#{@max_issued})" if issued_count >= @max_issued

            @prefixes[prefix] = { state: :issued, issued_at: monotonic_now }
          end
        end

        # Non-binding read: returns true if the prefix was issued and not yet consumed.
        def valid?(prefix)
          @monitor.synchronize do
            entry = @prefixes[prefix]
            entry.is_a?(Hash) && entry[:state] == :issued && !expired?(entry)
          end
        end

        # Atomically mark a prefix as consumed. Returns false if already consumed,
        # unknown, or expired.
        def consume!(prefix)
          @monitor.synchronize do
            entry = @prefixes[prefix]
            return false unless entry.is_a?(Hash) && entry[:state] == :issued && !expired?(entry)

            entry[:state] = :consumed
            true
          end
        end

        private

        def purge_expired!
          @prefixes.delete_if { |_, v| expired?(v) }
        end

        def expired?(entry)
          (monotonic_now - entry[:issued_at]) > @ttl
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
