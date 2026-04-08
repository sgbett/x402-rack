# frozen_string_literal: true

require "monitor"

module X402
  module BSV
    # Pluggable challenge cache for ProofGateway settlement.
    #
    # Stores issued challenges keyed by their canonical SHA-256 hash so that
    # the server can recover the full challenge object at settlement time
    # without trusting a client-echoed header. This is the provenance gate:
    # an attacker cannot submit a proof for a challenge that was never
    # issued by this server, because they cannot populate this store.
    #
    # The merkleworks spec only mandates that the client echoes
    # +challenge_sha256+ in the proof; it does not authorise the client to
    # echo the challenge itself. The server must recover the challenge
    # somehow to recompute the hash and check bindings — this cache is our
    # recovery mechanism.
    #
    # Duck-type contract — any backend must implement:
    #   store!(hash, challenge) — records an issued challenge by its
    #     canonical sha256 hex. Raises StoreFullError if at capacity.
    #   lookup(hash)            — returns the Challenge if present and not
    #     expired, otherwise nil. Non-binding read.
    #   consume!(hash)          — atomically removes the entry; returns
    #     true if it was present and active, false otherwise. Must be
    #     self-validating (not rely on a prior lookup).
    module ChallengeStore
      class StoreFullError < X402::Error; end

      # In-memory backend suitable for development and single-process
      # deployments. Thread-safe via Monitor. Entries expire after +ttl+
      # seconds and the store rejects new challenges once +max_issued+
      # unconsumed entries are held.
      #
      # NOTE: This store is per-process. It provides no replay protection
      # across OS processes (e.g. Puma pre-fork, multiple dynos). Production
      # multi-process deployments should use a shared backend.
      class Memory
        DEFAULT_TTL = 600
        DEFAULT_MAX_ISSUED = 10_000

        # @param ttl [Integer] seconds before an issued challenge expires
        # @param max_issued [Integer] cap on unconsumed entries
        def initialize(ttl: DEFAULT_TTL, max_issued: DEFAULT_MAX_ISSUED)
          @entries = {}
          @monitor = Monitor.new
          @ttl = ttl
          @max_issued = max_issued
        end

        # Record an issued challenge.
        #
        # @param hash [String] hex-encoded canonical sha256 of the challenge
        # @param challenge [X402::Challenge]
        # @return [void]
        # @raise [StoreFullError] if max_issued entries are held
        def store!(hash, challenge)
          @monitor.synchronize do
            purge_expired!
            raise StoreFullError, "challenge store at capacity (#{@max_issued})" if @entries.size >= @max_issued

            @entries[hash] = { challenge: challenge, issued_at: monotonic_now }
          end
        end

        # Non-binding read: returns the cached challenge or nil.
        #
        # @param hash [String]
        # @return [X402::Challenge, nil]
        def lookup(hash)
          @monitor.synchronize do
            entry = @entries[hash]
            return nil unless entry && !expired?(entry)

            entry[:challenge]
          end
        end

        # Atomically remove an entry. Returns true if it was present and
        # active, false otherwise. Safe to call from the settlement path
        # without a prior lookup.
        #
        # @param hash [String]
        # @return [Boolean]
        def consume!(hash)
          @monitor.synchronize do
            entry = @entries.delete(hash)
            entry && !expired?(entry) ? true : false
          end
        end

        private

        def purge_expired!
          @entries.delete_if { |_, entry| expired?(entry) }
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
