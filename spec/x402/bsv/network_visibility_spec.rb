# frozen_string_literal: true

require "logger"
require "x402/bsv/network_visibility"

RSpec.describe X402::BSV::NetworkVisibility do
  subject(:helper) { described_class }

  let(:arc_client) { instance_double(BSV::Network::ARC) }
  let(:cache) { described_class::Cache.new(ttl: 30) }
  let(:logger) { instance_double(Logger, warn: nil) }
  let(:sleeper) { ->(_s) {} }
  let(:txid) { "a" * 64 }

  def status_response(status)
    Struct.new(:txid, :tx_status).new(nil, status)
  end

  def call(**overrides)
    kwargs = {
      arc_client: arc_client,
      txid: txid,
      cache: cache,
      logger: logger,
      sleeper: sleeper
    }.merge(overrides)
    helper.verify!(**kwargs)
  end

  describe "happy path" do
    %w[SEEN_ON_NETWORK MINED CONFIRMED_ON_NETWORK].each do |status|
      it "succeeds on #{status} on the first attempt" do
        expect(arc_client).to receive(:status).with(txid).once.and_return(status_response(status))

        expect(call).to eq(status)
      end
    end

    it "succeeds on the final attempt (4th poll)" do
      responses = [
        status_response("UNKNOWN"),
        status_response("UNKNOWN"),
        status_response("UNKNOWN"),
        status_response("SEEN_ON_NETWORK")
      ]
      expect(arc_client).to receive(:status).with(txid).exactly(4).times do
        responses.shift
      end

      expect(call).to eq("SEEN_ON_NETWORK")
    end
  end

  describe "propagation delay" do
    it "retries once when ARC initially reports UNKNOWN then SEEN_ON_NETWORK" do
      responses = [status_response("UNKNOWN"), status_response("SEEN_ON_NETWORK")]
      expect(arc_client).to receive(:status).with(txid).twice do
        responses.shift
      end

      expect(call).to eq("SEEN_ON_NETWORK")
    end

    it "retries across STORED → SEEN_ON_NETWORK transition" do
      responses = [status_response("STORED"), status_response("SEEN_ON_NETWORK")]
      expect(arc_client).to receive(:status).with(txid).twice do
        responses.shift
      end

      expect(call).to eq("SEEN_ON_NETWORK")
    end
  end

  describe "propagation budget exhausted" do
    it "raises 402 when UNKNOWN across all 4 attempts" do
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_return(status_response("UNKNOWN"))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(402)
        expect(error.message).to include("not visible on the BSV network")
        expect(error.message).to include("last status: UNKNOWN")
      end
    end

    it "raises 402 when ARC returns a 404 BroadcastError across all attempts" do
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_raise(BSV::Network::BroadcastError.new("not found",
                                                                                        status_code: 404))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(402)
        expect(error.message).to include("last status: HTTP 404")
      end
    end

    it "raises 402 with 'unknown' last status when BroadcastError has no status_code" do
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_raise(BSV::Network::BroadcastError.new("odd"))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(402)
        expect(error.message).to include("last status: unknown")
      end
    end
  end

  describe "infrastructure fault" do
    it "raises 503 on ARC 500 BroadcastError" do
      expect(arc_client).to receive(:status).with(txid).once
                                            .and_raise(BSV::Network::BroadcastError.new("boom", status_code: 500))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(503)
        expect(error.message).to eq("payment verification temporarily unavailable")
      end
    end

    it "raises 503 on ARC 503 BroadcastError" do
      expect(arc_client).to receive(:status).with(txid).once
                                            .and_raise(BSV::Network::BroadcastError.new("unavail", status_code: 503))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(503)
      end
    end

    it "raises 503 on SocketError" do
      expect(arc_client).to receive(:status).with(txid).once.and_raise(SocketError.new("dns"))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(503)
      end
    end

    it "raises 503 on Timeout::Error" do
      expect(arc_client).to receive(:status).with(txid).once.and_raise(Timeout::Error.new("timed out"))

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(503)
      end
    end

    it "raises 503 on Errno::ECONNREFUSED" do
      expect(arc_client).to receive(:status).with(txid).once.and_raise(Errno::ECONNREFUSED)

      expect { call }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(503)
      end
    end
  end

  describe "cache behaviour" do
    it "returns a cached positive result without calling ARC" do
      expect(arc_client).to receive(:status).with(txid).once.and_return(status_response("SEEN_ON_NETWORK"))
      call
      expect(call).to eq("SEEN_ON_NETWORK")
    end

    it "re-checks ARC after the cache TTL expires" do
      short_cache = described_class::Cache.new(ttl: 0.01)
      expect(arc_client).to receive(:status).with(txid).twice.and_return(status_response("SEEN_ON_NETWORK"))

      call(cache: short_cache)
      sleep(0.02)
      call(cache: short_cache)
    end

    it "does NOT cache negative results (subsequent calls re-hit ARC)" do
      # Attempt 1: all UNKNOWN → 402 raised, cache stays empty.
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_return(status_response("UNKNOWN"))
      expect { call }.to raise_error(X402::VerificationError)

      # Attempt 2 (propagation has now happened): first poll visible.
      expect(arc_client).to receive(:status).with(txid).once.and_return(status_response("SEEN_ON_NETWORK"))
      expect(call).to eq("SEEN_ON_NETWORK")
    end

    it "does NOT cache after a 503 outage" do
      expect(arc_client).to receive(:status).with(txid).once
                                            .and_raise(BSV::Network::BroadcastError.new("boom", status_code: 500))
      expect { call }.to raise_error(X402::VerificationError)

      # ARC recovered: cache was not polluted by the outage.
      expect(arc_client).to receive(:status).with(txid).once.and_return(status_response("MINED"))
      expect(call).to eq("MINED")
    end
  end

  describe "visible_statuses kwarg" do
    it "respects a caller-supplied whitelist" do
      custom = %w[ACCEPTED_BY_NETWORK]
      expect(arc_client).to receive(:status).with(txid).once.and_return(status_response("ACCEPTED_BY_NETWORK"))

      expect(call(visible_statuses: custom)).to eq("ACCEPTED_BY_NETWORK")
    end

    it "rejects a status not in the caller-supplied whitelist" do
      custom = %w[MINED]
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_return(status_response("SEEN_ON_NETWORK"))

      expect { call(visible_statuses: custom) }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(402)
        expect(error.message).to include("last status: SEEN_ON_NETWORK")
      end
    end

    it "raises 402 when visible_statuses is empty" do
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_return(status_response("SEEN_ON_NETWORK"))

      expect { call(visible_statuses: []) }.to raise_error(X402::VerificationError) do |error|
        expect(error.status).to eq(402)
      end
    end
  end

  describe "unexpected status logging" do
    it "warns when ARC returns a status outside the known enum" do
      expect(arc_client).to receive(:status).with(txid).exactly(4).times
                                            .and_return(status_response("SOME_NEW_STATUS"))
      expect(logger).to receive(:warn).with(/unexpected status "SOME_NEW_STATUS"/).at_least(:once)

      expect { call }.to raise_error(X402::VerificationError)
    end
  end

  describe described_class::Cache do
    subject(:cache) { described_class.new(ttl: 30) }

    it "returns nil for a missing txid" do
      expect(cache.fetch("missing")).to be_nil
    end

    it "returns the stored status within TTL" do
      cache.store("abc", "MINED")
      expect(cache.fetch("abc")).to eq("MINED")
    end

    it "evicts expired entries on read" do
      short = described_class.new(ttl: 0.01)
      short.store("abc", "MINED")
      sleep(0.02)
      expect(short.fetch("abc")).to be_nil
    end

    it "is thread-safe under concurrent store/fetch" do
      threads = Array.new(20) do |i|
        Thread.new do
          cache.store("tx#{i}", "SEEN_ON_NETWORK")
          cache.fetch("tx#{i}")
        end
      end

      results = threads.map(&:value)
      expect(results).to all(eq("SEEN_ON_NETWORK"))
    end
  end
end
