# frozen_string_literal: true

require "monitor"

module X402
  module BSV
    # Centralised "is this txid visible on the BSV network via ARC?" check.
    #
    # Used by gateway settle paths to enforce that the client actually
    # broadcast the payment transaction before we mutate wallet / replay
    # state. A valid-looking BEEF is not proof of broadcast; ARC
    # observation is. This helper absorbs propagation lag with a bounded
    # retry loop, caches positive outcomes for a short TTL to protect ARC
    # from duplicate-submission bursts, and classifies failures cleanly:
    #
    #   * non-visible status (or 404 "unknown txid") → client fault → 402
    #   * 5xx / SocketError / Timeout                 → ARC outage    → 503
    #
    # Negative results are NEVER cached: propagation can flip UNKNOWN to
    # SEEN_ON_NETWORK at any moment, and a cached negative would delay
    # legitimate payments.
    module NetworkVisibility
      # ARC statuses that indicate the client successfully broadcast.
      # Kept deliberately tight (3 values) — distinct from
      # ProofGateway's 8-value "is my server's broadcast propagating?"
      # whitelist. `CONFIRMED_ON_NETWORK` is defensive forward-compat;
      # not yet documented in the SDK's ARC reference.
      VISIBLE_STATUSES = %w[SEEN_ON_NETWORK MINED CONFIRMED_ON_NETWORK].freeze

      # Backoff schedule between ARC polls. One immediate attempt plus
      # three retries → 4 attempts total, absorbing ~1.75 s of propagation
      # lag. Mirrors ProofGateway#check_mempool! timing.
      RETRY_DELAYS_SECONDS = [0.25, 0.5, 1.0].freeze

      NOT_VISIBLE_MESSAGE = "payment transaction not visible on the BSV network (last status: %s)"
      OUTAGE_MESSAGE = "payment verification temporarily unavailable"

      DEFAULT_SLEEPER = ->(seconds) { sleep(seconds) }

      module_function

      # Verify that +txid+ is visible on the BSV network via +arc_client+.
      #
      # Returns the observed status string on success. Raises
      # +X402::VerificationError+ with +status: 402+ on exhaustion with a
      # non-visible status, or +status: 503+ on ARC outage / network
      # fault.
      #
      # @param arc_client [#status] ARC client responding to +#status(txid)+
      # @param txid [String] hex transaction id to check
      # @param cache [Cache] per-gateway positive-only TTL cache
      # @param logger [#warn, nil] optional logger for unknown-status warnings
      # @param visible_statuses [Array<String>] statuses treated as success
      # @param sleeper [#call] injectable sleep lambda (for tests)
      # @return [String] the visible status that satisfied the check
      # @raise [X402::VerificationError] 402 on non-visible; 503 on outage
      def verify!(arc_client:, txid:, cache:, logger: nil, visible_statuses: VISIBLE_STATUSES,
                  sleeper: DEFAULT_SLEEPER)
        cached = cache.fetch(txid)
        return cached if cached

        last_status = poll_with_retries(arc_client, txid, visible_statuses, sleeper, logger)

        if visible_statuses.include?(last_status)
          cache.store(txid, last_status)
          return last_status
        end

        raise X402::VerificationError.new(
          format(NOT_VISIBLE_MESSAGE, last_status || "unknown"),
          status: 402
        )
      end

      # Poll ARC up to +RETRY_DELAYS_SECONDS.length + 1+ times, returning
      # the last status string seen. Returns early on the first visible
      # status. Rescues +BroadcastError+ to inspect +status_code+:
      # non-5xx means the txid is unknown to ARC (client fault) and we
      # keep retrying; 5xx plus +SocketError+/+Timeout::Error+ fail fast
      # as an outage.
      def poll_with_retries(arc_client, txid, visible_statuses, sleeper, logger)
        attempts = RETRY_DELAYS_SECONDS.length + 1
        last_status = nil

        attempts.times do |i|
          last_status = fetch_status(arc_client, txid, logger)
          break if visible_statuses.include?(last_status)

          sleeper.call(RETRY_DELAYS_SECONDS[i]) if i < RETRY_DELAYS_SECONDS.length
        end

        last_status
      end
      private_class_method :poll_with_retries

      # One ARC call. Returns the status string, or a nil-ish marker for
      # "unknown" when ARC reports the txid isn't known (404-style
      # BroadcastError). Raises +VerificationError(503)+ for
      # infrastructure faults.
      def fetch_status(arc_client, txid, logger)
        response = arc_client.status(txid)
        status = response.tx_status
        logger&.warn("[x402] ARC returned unexpected status #{status.inspect} for #{txid}") if unexpected?(status)
        status
      rescue ::BSV::Network::BroadcastError => e
        raise_outage! if outage_status_code?(e.status_code)

        # Client fault (txid unknown to ARC, malformed request, etc.).
        # Surface the status_code so the caller's error message can
        # distinguish "404" from "UNKNOWN" without the specifics leaking
        # to the HTTP client.
        e.status_code ? "HTTP #{e.status_code}" : "unknown"
      rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ETIMEDOUT, Errno::EHOSTUNREACH
        raise_outage!
      end
      private_class_method :fetch_status

      def outage_status_code?(code)
        code.is_a?(Integer) && code >= 500
      end
      private_class_method :outage_status_code?

      def unexpected?(status)
        return false if status.nil?

        !VISIBLE_STATUSES.include?(status) && !KNOWN_NON_VISIBLE.include?(status)
      end
      private_class_method :unexpected?

      # Non-visible statuses the SDK may surface. Logged at WARN if a
      # response falls outside this plus +VISIBLE_STATUSES+ — surfaces
      # ARC enum drift without failing the request.
      KNOWN_NON_VISIBLE = %w[
        UNKNOWN
        QUEUED
        RECEIVED
        STORED
        ANNOUNCED_TO_NETWORK
        REQUESTED_BY_NETWORK
        SENT_TO_NETWORK
        ACCEPTED_BY_NETWORK
      ].freeze

      def raise_outage!
        raise X402::VerificationError.new(OUTAGE_MESSAGE, status: 503)
      end
      private_class_method :raise_outage!

      # Per-gateway positive-only TTL cache keyed by txid.
      #
      # Protects ARC from duplicate-submission bursts (two near-
      # simultaneous requests with the same proof) without masking
      # genuine propagation. Entries expire after +ttl+ seconds;
      # expired entries are pruned opportunistically on read.
      # +Mutex+-guarded for multi-threaded Rack deployments.
      class Cache
        DEFAULT_TTL = 30

        # @param ttl [Integer] seconds a positive observation remains fresh
        def initialize(ttl: DEFAULT_TTL)
          @ttl = ttl
          @entries = {}
          @mutex = Mutex.new
        end

        # Returns the cached status for +txid+, or +nil+ if absent or
        # expired. Expired entries are dropped on read.
        def fetch(txid)
          @mutex.synchronize do
            entry = @entries[txid]
            return nil unless entry

            if expired?(entry)
              @entries.delete(txid)
              return nil
            end

            entry[:status]
          end
        end

        # Records a positive observation. Callers MUST only store
        # visible statuses — negative results are never cached.
        def store(txid, status)
          @mutex.synchronize do
            @entries[txid] = { status: status, cached_at: monotonic_now }
          end
        end

        private

        def expired?(entry)
          (monotonic_now - entry[:cached_at]) >= @ttl
        end

        def monotonic_now
          Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
      end
    end
  end
end
