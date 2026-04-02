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
