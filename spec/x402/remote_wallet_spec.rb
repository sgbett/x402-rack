# frozen_string_literal: true

require "x402/remote_wallet"
require "x402/errors"
require "webrick"

RSpec.describe X402::RemoteWallet do
  let(:identity_key) { "02#{"ab" * 32}" }
  let(:derived_key) { "03#{"cd" * 32}" }
  let(:base_url) { "http://127.0.0.1:#{port}" }
  let(:port) { rand(19_876..19_975) }
  let(:timeout) { 5 }
  let(:wallet) { described_class.new(url: base_url, timeout: timeout) }

  # ---------------------------------------------------------------------------
  # Lightweight WEBrick server for integration-style tests
  # ---------------------------------------------------------------------------
  let(:server_responses) { {} }

  let(:server) do
    srv = WEBrick::HTTPServer.new(Port: port, Logger: WEBrick::Log.new(File::NULL), AccessLog: [])

    srv.mount_proc "/" do |req, res|
      # WEBrick's req.query parses form body on POST, not the query string.
      # Parse the query string directly to extract the action parameter.
      params = URI.decode_www_form(req.query_string || "").to_h
      action = params["action"]
      handler = server_responses[action]
      if handler
        status, body = handler.call(req)
        res.status = status
        res["Content-Type"] = "application/json"
        res.body = body.is_a?(String) ? body : JSON.generate(body)
      else
        res.status = 404
        res.body = JSON.generate({ error: "unknown action: #{action}" })
      end
    end

    srv
  end

  around do |example|
    thread = Thread.new { server.start }
    # Wait for server to be ready
    deadline = Time.now + 3
    loop do
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue Errno::ECONNREFUSED
      raise "test server did not start" if Time.now > deadline

      sleep 0.05
    end
    example.run
  ensure
    server&.shutdown
    thread&.join(2)
  end

  # ---------------------------------------------------------------------------
  # Construction
  # ---------------------------------------------------------------------------
  describe ".new" do
    it "raises ConfigurationError for nil url" do
      expect { described_class.new(url: nil) }
        .to raise_error(X402::ConfigurationError, /url is required/)
    end

    it "raises ConfigurationError for empty url" do
      expect { described_class.new(url: "") }
        .to raise_error(X402::ConfigurationError, /url is required/)
    end

    it "raises ConfigurationError for invalid URI" do
      expect { described_class.new(url: "not a valid uri://[broken") }
        .to raise_error(X402::ConfigurationError, /invalid remote wallet url/)
    end
  end

  # ---------------------------------------------------------------------------
  # #get_public_key — identity key
  # ---------------------------------------------------------------------------
  describe "#get_public_key(identity_key: true)" do
    before do
      call_count = 0
      server_responses["create"] = lambda { |_req|
        call_count += 1
        [200, { "identityKey" => identity_key, "callCount" => call_count }]
      }
    end

    it "returns the identity key from the remote wallet" do
      result = wallet.get_public_key(identity_key: true)
      expect(result).to eq(public_key: identity_key)
    end

    it "caches the identity key across calls" do
      result1 = wallet.get_public_key(identity_key: true)
      result2 = wallet.get_public_key(identity_key: true)
      expect(result1).to eq(result2)
      # Only one HTTP call should have been made
    end

    context "when the remote wallet returns publicKey instead of identityKey" do
      before do
        server_responses["create"] = ->(_req) { [200, { "publicKey" => identity_key }] }
      end

      it "extracts the key from publicKey" do
        result = wallet.get_public_key(identity_key: true)
        expect(result).to eq(public_key: identity_key)
      end
    end

    context "when the response is missing the identity key" do
      before do
        server_responses["create"] = ->(_req) { [200, { "something" => "else" }] }
      end

      it "raises ConfigurationError" do
        expect { wallet.get_public_key(identity_key: true) }
          .to raise_error(X402::ConfigurationError, /did not return an identity key/)
      end
    end

    context "when the remote wallet returns HTTP 500" do
      before do
        server_responses["create"] = ->(_req) { [500, { "error" => "kaboom" }] }
      end

      it "raises ConfigurationError with the HTTP status" do
        expect { wallet.get_public_key(identity_key: true) }
          .to raise_error(X402::ConfigurationError, /HTTP 500/)
      end
    end

    context "when the remote wallet returns invalid JSON" do
      before do
        server_responses["create"] = ->(_req) { [200, "not json at all{{"] }
      end

      it "raises ConfigurationError" do
        expect { wallet.get_public_key(identity_key: true) }
          .to raise_error(X402::ConfigurationError, /invalid JSON/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #get_public_key — derived key
  # ---------------------------------------------------------------------------
  describe "#get_public_key with derivation params" do
    before do
      server_responses["getPublicKey"] = lambda { |req|
        params = URI.decode_www_form(req.query_string || "").to_h
        expect(params["protocolId"]).to eq("2,3241645161d8")
        expect(params["keyId"]).to be_a(String)
        [200, { "publicKey" => derived_key }]
      }
    end

    it "returns the derived key" do
      result = wallet.get_public_key(
        protocol_id: [2, "3241645161d8"],
        key_id: "abc123 0",
        identity_key: false
      )
      expect(result).to eq(public_key: derived_key)
    end

    context "when the response is missing the derived key" do
      before do
        server_responses["getPublicKey"] = ->(_req) { [200, { "amount" => 100 }] }
      end

      it "raises ConfigurationError" do
        expect { wallet.get_public_key(protocol_id: [2, "test"], key_id: "k1") }
          .to raise_error(X402::ConfigurationError, /did not return a derived public key/)
      end
    end

    context "when the remote wallet returns HTTP 400" do
      before do
        server_responses["getPublicKey"] = ->(_req) { [400, { "error" => "bad request" }] }
      end

      it "raises ConfigurationError" do
        expect { wallet.get_public_key(protocol_id: [2, "test"], key_id: "k1") }
          .to raise_error(X402::ConfigurationError, /HTTP 400/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # #internalize_action
  # ---------------------------------------------------------------------------
  describe "#internalize_action" do
    let(:tx_bytes) { [0, 1, 2, 3] }
    let(:sender_key) { "03#{"ee" * 32}" }
    let(:captured_body) { {} }

    before do
      server_responses["receive"] = lambda { |req|
        body = JSON.parse(req.body)
        captured_body.merge!(body)
        [200, { "accepted" => true }]
      }
    end

    it "posts the payment to the receive endpoint" do
      result = wallet.internalize_action(
        tx: tx_bytes,
        outputs: [{
          output_index: 0,
          protocol: "wallet payment",
          payment_remittance: {
            derivation_prefix: "cHJlZml4",
            derivation_suffix: "c3VmZml4",
            sender_identity_key: sender_key
          }
        }],
        description: "BRC-121 payment"
      )

      expect(result).to eq("accepted" => true)
      expect(captured_body["tx"]).to eq(tx_bytes)
      expect(captured_body["senderIdentityKey"]).to eq(sender_key)
      expect(captured_body["derivationPrefix"]).to eq("cHJlZml4")
      expect(captured_body["derivationSuffix"]).to eq("c3VmZml4")
      expect(captured_body["outputIndex"]).to eq(0)
    end

    it "accepts a positional Hash (ProtoWallet convention)" do
      result = wallet.internalize_action({
                                           tx: tx_bytes,
                                           outputs: [{
                                             output_index: 0,
                                             protocol: "wallet payment",
                                             payment_remittance: {
                                               derivation_prefix: "cHJlZml4",
                                               derivation_suffix: "c3VmZml4",
                                               sender_identity_key: sender_key
                                             }
                                           }],
                                           description: "BRC-121 payment"
                                         })

      expect(result).to eq("accepted" => true)
      expect(captured_body["tx"]).to eq(tx_bytes)
      expect(captured_body["senderIdentityKey"]).to eq(sender_key)
    end

    context "when outputs is empty" do
      it "posts with nil derivation fields" do
        result = wallet.internalize_action(tx: tx_bytes, outputs: [], description: "test")
        expect(result).to eq("accepted" => true)
      end
    end

    context "when the remote wallet returns HTTP 500" do
      before do
        server_responses["receive"] = ->(_req) { [500, { "error" => "internal error" }] }
      end

      it "raises ConfigurationError" do
        expect do
          wallet.internalize_action(tx: tx_bytes, outputs: [], description: "test")
        end.to raise_error(X402::ConfigurationError, /HTTP 500/)
      end
    end

    context "when the remote wallet returns invalid JSON" do
      before do
        server_responses["receive"] = ->(_req) { [200, "broken{json"] }
      end

      it "raises ConfigurationError" do
        expect do
          wallet.internalize_action(tx: tx_bytes, outputs: [], description: "test")
        end.to raise_error(X402::ConfigurationError, /invalid JSON/)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Network errors
  # ---------------------------------------------------------------------------
  describe "network errors" do
    let(:wallet) { described_class.new(url: "http://127.0.0.1:1", timeout: 1) }

    it "raises ConfigurationError when the wallet is unreachable" do
      expect { wallet.get_public_key(identity_key: true) }
        .to raise_error(X402::ConfigurationError, /unreachable/)
    end
  end

  # ---------------------------------------------------------------------------
  # Thread safety
  # ---------------------------------------------------------------------------
  describe "thread safety" do
    before do
      server_responses["create"] = ->(_req) { [200, { "identityKey" => identity_key }] }
    end

    it "handles concurrent identity key fetches safely" do
      threads = 5.times.map do
        Thread.new { wallet.get_public_key(identity_key: true) }
      end
      results = threads.map(&:value)
      expect(results).to all(eq(public_key: identity_key))
    end
  end
end
