# frozen_string_literal: true

require "x402/settlement_worker"

RSpec.describe X402::SettlementWorker do
  let(:broadcast_result) { Struct.new(:tx_status).new("SEEN_ON_NETWORK") }
  let(:arc_client) { instance_double("ArcClient") }
  let(:worker) { described_class.new(arc_client: arc_client, max_retries: 3) }
  let(:tx_binary) { "fake-tx-binary" }

  after { worker.stop rescue nil } # rubocop:disable Style/RescueModifier

  describe "#enqueue" do
    it "broadcasts the transaction to ARC" do
      allow(arc_client).to receive(:broadcast).and_return(broadcast_result)

      worker.enqueue(tx_binary)
      worker.stop

      expect(arc_client).to have_received(:broadcast).with(tx_binary, wait_for: "SEEN_ON_NETWORK")
    end

    it "processes multiple enqueued transactions" do
      allow(arc_client).to receive(:broadcast).and_return(broadcast_result)

      worker.enqueue("tx1")
      worker.enqueue("tx2")
      worker.stop

      expect(arc_client).to have_received(:broadcast).with("tx1", wait_for: "SEEN_ON_NETWORK")
      expect(arc_client).to have_received(:broadcast).with("tx2", wait_for: "SEEN_ON_NETWORK")
    end
  end

  describe "retry behaviour" do
    let(:rejected_result) { Struct.new(:tx_status).new("REJECTED") }

    before { allow(worker).to receive(:sleep) }

    it "retries on non-acceptable status with exponential backoff" do
      call_count = 0
      allow(arc_client).to receive(:broadcast) do
        call_count += 1
        call_count < 3 ? rejected_result : broadcast_result
      end

      worker.enqueue(tx_binary)
      worker.stop

      expect(arc_client).to have_received(:broadcast).exactly(3).times
      expect(worker).to have_received(:sleep).with(1).once
      expect(worker).to have_received(:sleep).with(2).once
    end

    it "stops after max_retries attempts" do
      allow(arc_client).to receive(:broadcast).and_return(rejected_result)

      worker.enqueue(tx_binary)
      worker.stop

      # Initial attempt + 3 retries = 4 calls
      expect(arc_client).to have_received(:broadcast).exactly(4).times
    end

    it "retries on exceptions with exponential backoff" do
      call_count = 0
      allow(arc_client).to receive(:broadcast) do
        call_count += 1
        raise "connection refused" if call_count < 3

        broadcast_result
      end

      worker.enqueue(tx_binary)
      worker.stop

      expect(arc_client).to have_received(:broadcast).exactly(3).times
      expect(worker).to have_received(:sleep).with(1).once
      expect(worker).to have_received(:sleep).with(2).once
    end

    it "stops retrying exceptions after max_retries" do
      allow(arc_client).to receive(:broadcast).and_raise("connection refused")

      worker.enqueue(tx_binary)
      worker.stop

      # Initial attempt + 3 retries = 4 calls
      expect(arc_client).to have_received(:broadcast).exactly(4).times
    end
  end

  describe "on_failure callback" do
    let(:failures) { [] }
    let(:callback) { ->(tx, error) { failures << [tx, error] } }
    let(:worker) { described_class.new(arc_client: arc_client, max_retries: 1, on_failure: callback) }
    let(:rejected_result) { Struct.new(:tx_status).new("REJECTED") }

    before { allow(worker).to receive(:sleep) }

    it "invokes callback when retries exhausted on bad status" do
      allow(arc_client).to receive(:broadcast).and_return(rejected_result)

      worker.enqueue(tx_binary)
      worker.stop

      expect(failures.size).to eq(1)
      expect(failures.first[0]).to eq(tx_binary)
      expect(failures.first[1]).to include("REJECTED")
    end

    it "invokes callback when retries exhausted on exception" do
      allow(arc_client).to receive(:broadcast).and_raise("connection refused")

      worker.enqueue(tx_binary)
      worker.stop

      expect(failures.size).to eq(1)
      expect(failures.first[0]).to eq(tx_binary)
      expect(failures.first[1]).to be_a(RuntimeError)
    end

    it "does not invoke callback on success" do
      allow(arc_client).to receive(:broadcast).and_return(broadcast_result)

      worker.enqueue(tx_binary)
      worker.stop

      expect(failures).to be_empty
    end

    it "survives callback that raises" do
      bad_callback = ->(_tx, _error) { raise "callback exploded" }
      w = described_class.new(arc_client: arc_client, max_retries: 0, on_failure: bad_callback)
      allow(w).to receive(:sleep)
      allow(arc_client).to receive(:broadcast).and_return(rejected_result)

      w.enqueue(tx_binary)
      w.stop

      # Worker thread survived — no exception propagated
      expect(arc_client).to have_received(:broadcast).once
    end
  end

  describe "queue capacity" do
    it "raises VerificationError (503) when queue is full" do
      small_worker = described_class.new(arc_client: arc_client, max_queue: 2)
      # Don't start the consumer thread — fill the queue manually
      allow(arc_client).to receive(:broadcast).and_return(broadcast_result)

      # Fill the queue without starting the worker thread
      small_worker.instance_variable_get(:@queue).push("tx1")
      small_worker.instance_variable_get(:@queue).push("tx2")

      expect { small_worker.enqueue("tx3") }
        .to raise_error(X402::VerificationError, /queue full/) { |e| expect(e.status).to eq(503) }

      small_worker.stop rescue nil # rubocop:disable Style/RescueModifier
    end

    it "defaults to 1000 capacity" do
      default_worker = described_class.new(arc_client: arc_client)
      expect(default_worker.max_queue).to eq(1000)
      default_worker.stop rescue nil # rubocop:disable Style/RescueModifier
    end
  end

  describe "#stop" do
    it "drains the queue and joins the thread" do
      allow(arc_client).to receive(:broadcast).and_return(broadcast_result)

      worker.enqueue(tx_binary)
      worker.stop

      expect(arc_client).to have_received(:broadcast).with(tx_binary, wait_for: "SEEN_ON_NETWORK")
    end

    it "is safe to call when no thread has started" do
      expect { worker.stop }.not_to raise_error
    end
  end

  describe "lazy thread start" do
    it "does not start a thread until first enqueue" do
      # Access the internal thread — should be nil before any enqueue
      expect(worker.instance_variable_get(:@thread)).to be_nil
    end

    it "starts a thread on first enqueue" do
      allow(arc_client).to receive(:broadcast).and_return(broadcast_result)

      worker.enqueue(tx_binary)

      expect(worker.instance_variable_get(:@thread)).to be_a(Thread)
      worker.stop
    end
  end
end
