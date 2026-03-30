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
    #   store!(prefix)   — records a prefix as issued
    #   valid?(prefix)   — true if prefix was issued and not yet consumed
    #   consume!(prefix)  — marks prefix as used; returns false if already consumed or unknown
    module PrefixStore
      # In-memory backend suitable for development and testing.
      # Thread-safe via Monitor.
      class Memory
        def initialize
          @prefixes = {}
          @monitor = Monitor.new
        end

        # Record a prefix as issued.
        def store!(prefix)
          @monitor.synchronize do
            @prefixes[prefix] = :issued
          end
        end

        # Returns true if the prefix was issued and not yet consumed.
        def valid?(prefix)
          @monitor.synchronize do
            @prefixes[prefix] == :issued
          end
        end

        # Mark a prefix as consumed. Returns false if already consumed or unknown.
        def consume!(prefix)
          @monitor.synchronize do
            return false unless @prefixes[prefix] == :issued

            @prefixes[prefix] = :consumed
            true
          end
        end
      end
    end
  end
end
