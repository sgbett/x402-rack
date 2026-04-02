# frozen_string_literal: true

require "rack"
require "json"
require "base64"
require "x402/bsv"

RSpec.describe X402::BSV::PayGateway do
  let(:payee_hex) { "76a914#{"aa" * 20}88ac" }
  let(:payee_script) { BSV::Script::Script.from_hex(payee_hex) }
  let(:route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 100) }

  let(:mock_arc) do
    arc = Object.new
    def arc.broadcast(_transaction, **)
      Struct.new(:txid, :tx_status).new("cc" * 32, "SEEN_ON_NETWORK")
    end
    arc
  end

  let(:gateway) do
    described_class.new(
      arc_client: mock_arc,
      payee_locking_script_hex: payee_hex
    )
  end

  def mock_request(method: "GET", path: "/premium", query: "")
    url = query.empty? ? path : "#{path}?#{query}"
    env = Rack::MockRequest.env_for(url, method: method)
    Rack::Request.new(env)
  end

  # Build a valid payment tx from the gateway's template
  def build_valid_tx(request: mock_request, route_override: nil)
    r = route_override || route
    template, = gateway.build_template(request, r)

    # Add a funding input (dummy)
    nonce_txid_bytes = ["dd" * 32].pack("H*")
    template.add_input(BSV::Transaction::TransactionInput.new(
                         prev_tx_id: nonce_txid_bytes,
                         prev_tx_out_index: 0,
                         unlocking_script: BSV::Script::Script.new("\x00".b)
                       ))
    template
  end

  # Extract the accepted block from a gateway's challenge (includes payToSig)
  def accepted_from_challenge(gateway_inst = gateway, req = mock_request)
    headers = gateway_inst.challenge_headers(req, route)
    challenge = JSON.parse(Base64.strict_decode64(headers["Payment-Required"]))
    challenge["accepts"].first
  end

  def encode_payment_payload(transaction, accepted_overrides: {}, gateway_instance: gateway)
    accepted = accepted_from_challenge(gateway_instance).merge(accepted_overrides)

    payload = {
      "x402Version" => 2,
      "accepted" => accepted,
      "payload" => {
        "rawtx" => transaction.to_binary.unpack1("H*"),
        "txid" => transaction.txid_hex
      }
    }

    Base64.strict_encode64(JSON.generate(payload))
  end

  describe "#challenge_headers" do
    let(:request) { mock_request }
    let(:headers) { gateway.challenge_headers(request, route) }

    it "returns a hash with Payment-Required key" do
      expect(headers).to have_key("Payment-Required")
    end

    it "contains valid base64-encoded JSON" do
      json = Base64.strict_decode64(headers["Payment-Required"])
      challenge = JSON.parse(json)
      expect(challenge).to be_a(Hash)
    end

    it "sets x402Version to 2" do
      challenge = JSON.parse(Base64.strict_decode64(headers["Payment-Required"]))
      expect(challenge["x402Version"]).to eq(2)
    end

    it "includes resource URL" do
      challenge = JSON.parse(Base64.strict_decode64(headers["Payment-Required"]))
      expect(challenge["resource"]["url"]).to eq("/premium")
    end

    it "includes accepts array with BSV entry" do
      challenge = JSON.parse(Base64.strict_decode64(headers["Payment-Required"]))
      accept = challenge["accepts"].first
      expect(accept["scheme"]).to eq("exact")
      expect(accept["network"]).to eq("bsv:mainnet")
      expect(accept["amount"]).to eq("100")
      expect(accept["asset"]).to eq("BSV")
      expect(accept["payTo"]).to eq(payee_hex)
    end

    it "includes extra.partialTx with base64-encoded template" do
      challenge = JSON.parse(Base64.strict_decode64(headers["Payment-Required"]))
      partial_tx_b64 = challenge["accepts"].first.dig("extra", "partialTx")
      expect(partial_tx_b64).not_to be_nil

      tx_binary = Base64.strict_decode64(partial_tx_b64)
      tx = BSV::Transaction::Transaction.from_binary(tx_binary)
      expect(tx.outputs.size).to eq(2)
      expect(tx.outputs[0].satoshis).to eq(100)
      expect(tx.outputs[1].locking_script.op_return?).to be true
    end
  end

  describe "#proof_header_names" do
    it "returns Payment-Signature" do
      expect(gateway.proof_header_names).to eq(["Payment-Signature"])
    end
  end

  describe "#settle!" do
    let(:request) { mock_request }
    let(:tx) { build_valid_tx }
    let(:proof) { encode_payment_payload(tx) }

    it "returns a SettlementResult on success" do
      result = gateway.settle!("Payment-Signature", proof, request, route)
      expect(result).to be_a(X402::SettlementResult)
      expect(result.network).to eq("bsv:mainnet")
      expect(result.txid).to eq(tx.txid_hex)
    end

    it "includes Payment-Response receipt header" do
      result = gateway.settle!("Payment-Signature", proof, request, route)
      expect(result.receipt_headers).to have_key("Payment-Response")

      receipt = JSON.parse(Base64.strict_decode64(result.receipt_headers["Payment-Response"]))
      expect(receipt["success"]).to be true
      expect(receipt["network"]).to eq("bsv:mainnet")
    end

    context "with insufficient payment" do
      let(:small_route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 10) }
      let(:small_tx) { build_valid_tx(route_override: small_route) }
      let(:proof) { encode_payment_payload(small_tx, accepted_overrides: { "amount" => "10" }) }

      it "raises VerificationError with 402 when payment output is insufficient" do
        expect { gateway.settle!("Payment-Signature", proof, request, route) }
          .to raise_error(X402::VerificationError) { |e| expect(e.status).to eq(402) }
      end
    end

    context "with wrong payee" do
      it "raises VerificationError when no output pays the correct payee" do
        # Build tx with wrong payee
        wrong_payee = "76a914#{"bb" * 20}88ac"
        wrong_script = BSV::Script::Script.from_hex(wrong_payee)

        tx = BSV::Transaction::Transaction.new
        tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 100, locking_script: wrong_script))
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_tx_id: ["dd" * 32].pack("H*"),
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.new("\x00".b)
                     ))

        proof = encode_payment_payload(tx)
        expect { gateway.settle!("Payment-Signature", proof, request, route) }
          .to raise_error(X402::VerificationError, /payee/)
      end
    end

    context "with tampered payTo" do
      it "raises VerificationError when payTo is changed" do
        attacker_payee = "76a914#{"ff" * 20}88ac"
        proof = encode_payment_payload(tx, accepted_overrides: { "payTo" => attacker_payee })
        expect { gateway.settle!("Payment-Signature", proof, request, route) }
          .to raise_error(X402::VerificationError, /payTo signature mismatch/)
      end

      it "raises VerificationError when payToSig is missing" do
        accepted = accepted_from_challenge
        accepted["extra"].delete("payToSig")
        raw = { "x402Version" => 2, "accepted" => accepted,
                "payload" => { "rawtx" => tx.to_binary.unpack1("H*"), "txid" => tx.txid_hex } }
        payload = Base64.strict_encode64(JSON.generate(raw))
        expect { gateway.settle!("Payment-Signature", payload, request, route) }
          .to raise_error(X402::VerificationError, /payTo signature mismatch/)
      end
    end

    context "with wrong network" do
      it "raises VerificationError" do
        proof = encode_payment_payload(tx, accepted_overrides: { "network" => "eip155:1" })
        expect { gateway.settle!("Payment-Signature", proof, request, route) }
          .to raise_error(X402::VerificationError, /network/)
      end
    end

    context "with ARC broadcast failure" do
      let(:failing_arc) do
        arc = Object.new
        def arc.broadcast(_transaction, **)
          raise "connection refused"
        end
        arc
      end

      let(:gateway) do
        described_class.new(arc_client: failing_arc, payee_locking_script_hex: payee_hex)
      end

      it "raises VerificationError with 502" do
        expect { gateway.settle!("Payment-Signature", proof, request, route) }
          .to raise_error(X402::VerificationError) { |e| expect(e.status).to eq(502) }
      end
    end

    context "with invalid payload" do
      it "raises VerificationError for malformed base64" do
        expect { gateway.settle!("Payment-Signature", "!!!invalid!!!", request, route) }
          .to raise_error(X402::VerificationError) { |e| expect(e.status).to eq(400) }
      end

      it "raises VerificationError for missing rawtx" do
        accepted = accepted_from_challenge
        raw = {
          "x402Version" => 2,
          "accepted" => accepted,
          "payload" => {}
        }
        payload = Base64.strict_encode64(JSON.generate(raw))
        expect { gateway.settle!("Payment-Signature", payload, request, route) }
          .to raise_error(X402::VerificationError, /rawtx/)
      end
    end

    context "binding mode" do
      it "accepts tx without OP_RETURN in permissive mode" do
        # Build tx with payment but no OP_RETURN
        tx = BSV::Transaction::Transaction.new
        tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 100, locking_script: payee_script))
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_tx_id: ["dd" * 32].pack("H*"),
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.new("\x00".b)
                     ))

        proof = encode_payment_payload(tx)
        result = gateway.settle!("Payment-Signature", proof, request, route)
        expect(result).to be_a(X402::SettlementResult)
      end

      it "rejects tx without OP_RETURN in strict mode" do
        strict_gw = described_class.new(
          arc_client: mock_arc,
          payee_locking_script_hex: payee_hex,
          binding_mode: :strict
        )

        tx = BSV::Transaction::Transaction.new
        tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 100, locking_script: payee_script))
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_tx_id: ["dd" * 32].pack("H*"),
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.new("\x00".b)
                     ))

        proof = encode_payment_payload(tx, gateway_instance: strict_gw)
        expect { strict_gw.settle!("Payment-Signature", proof, request, route) }
          .to raise_error(X402::VerificationError, /binding/)
      end
    end

    context "async settlement" do
      let(:mock_worker) { instance_double("X402::SettlementWorker") }

      let(:async_gateway) do
        described_class.new(
          arc_client: mock_arc,
          payee_locking_script_hex: payee_hex,
          settlement_worker: mock_worker
        )
      end

      let(:async_route) do
        X402::Configuration::Route.new(
          http_method: "GET", path: "/premium", amount_sats: 100, arc_wait_for: :async
        )
      end

      def async_proof(gw_instance)
        tx = build_valid_tx
        encode_payment_payload(tx, gateway_instance: gw_instance)
      end

      it "enqueues to worker when route arc_wait_for is :async" do
        allow(mock_worker).to receive(:enqueue)
        proof = async_proof(async_gateway)

        result = async_gateway.settle!("Payment-Signature", proof, request, async_route)

        expect(result).to be_a(X402::SettlementResult)
        expect(mock_worker).to have_received(:enqueue).once
      end

      it "raises ConfigurationError when :async but no worker" do
        no_worker_gw = described_class.new(
          arc_client: mock_arc,
          payee_locking_script_hex: payee_hex
        )

        proof = async_proof(no_worker_gw)
        expect { no_worker_gw.settle!("Payment-Signature", proof, request, async_route) }
          .to raise_error(X402::ConfigurationError, /settlement_worker/)
      end

      it "falls back to gateway default when route arc_wait_for is nil" do
        proof = async_proof(async_gateway)

        # nil arc_wait_for route — should broadcast synchronously with default
        result = async_gateway.settle!("Payment-Signature", proof, request, route)
        expect(result).to be_a(X402::SettlementResult)
      end

      it "uses route arc_wait_for string to override gateway default" do
        mined_route = X402::Configuration::Route.new(
          http_method: "GET", path: "/premium", amount_sats: 100, arc_wait_for: "MINED"
        )

        # Create a custom arc that records the wait_for argument
        recorded_wait_for = nil
        custom_arc = Object.new
        custom_arc.define_singleton_method(:broadcast) do |_tx, **kwargs|
          recorded_wait_for = kwargs[:wait_for]
          Struct.new(:txid, :tx_status).new("cc" * 32, "MINED")
        end

        custom_gw = described_class.new(
          arc_client: custom_arc,
          payee_locking_script_hex: payee_hex
        )

        proof = async_proof(custom_gw)
        custom_gw.settle!("Payment-Signature", proof, request, mined_route)

        expect(recorded_wait_for).to eq("MINED")
      end

      it "runs all validation before async enqueue" do
        allow(mock_worker).to receive(:enqueue)

        # Build proof with wrong network — should fail validation before reaching enqueue
        tx = build_valid_tx
        proof = encode_payment_payload(tx, accepted_overrides: { "network" => "eip155:1" },
                                           gateway_instance: async_gateway)

        expect { async_gateway.settle!("Payment-Signature", proof, request, async_route) }
          .to raise_error(X402::VerificationError, /network/)
        expect(mock_worker).not_to have_received(:enqueue)
      end
    end
  end
end
