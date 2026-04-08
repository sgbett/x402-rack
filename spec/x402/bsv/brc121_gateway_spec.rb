# frozen_string_literal: true

require "rack"
require "base64"
require "securerandom"
require "bsv-sdk"
require "x402/bsv/brc121_gateway"
require "x402/bsv/txid_store"

RSpec.describe X402::BSV::BRC121Gateway do
  let(:server_identity_key) { "02#{"ab" * 32}" }
  let(:client_identity_key) { "03#{"cd" * 32}" }

  # Mock BRC-100 wallet: supports get_public_key and internalize_action.
  let(:wallet) do
    w = double("wallet")
    allow(w).to receive(:get_public_key).with(identity_key: true).and_return(public_key: server_identity_key)
    allow(w).to receive(:internalize_action).and_return(accepted: true)
    w
  end

  let(:txid_store) { X402::BSV::TxidStore::Memory.new }
  let(:gateway) { described_class.new(wallet: wallet, txid_store: txid_store) }
  let(:route) { X402::Configuration::Route.new(http_method: "GET", path: "/premium", amount_sats: 1000) }

  def mock_request(env_overrides = {})
    env = Rack::MockRequest.env_for("/premium", method: "GET")
    env.merge!(env_overrides)
    Rack::Request.new(env)
  end

  def build_payment_tx(amount: 1000)
    tx = BSV::Transaction::Transaction.new
    tx.add_input(BSV::Transaction::TransactionInput.new(
                   prev_tx_id: ["ee" * 32].pack("H*"),
                   prev_tx_out_index: 0,
                   unlocking_script: BSV::Script::Script.new("\x00".b)
                 ))
    tx.add_output(BSV::Transaction::TransactionOutput.new(
                    satoshis: amount,
                    locking_script: BSV::Script::Script.from_hex("76a914#{"11" * 20}88ac")
                  ))
    tx
  end

  def build_beef_b64(transaction)
    beef = BSV::Transaction::Beef.new
    beef.merge_transaction(transaction)
    Base64.strict_encode64(beef.to_atomic_binary(transaction.txid))
  end

  def paid_request_env(beef_b64:, sender: client_identity_key, nonce: Base64.strict_encode64(SecureRandom.hex(16)),
                       time: (Time.now.to_f * 1000).to_i.to_s, vout: "0", overrides: {})
    {
      "HTTP_X_BSV_BEEF" => beef_b64,
      "HTTP_X_BSV_SENDER" => sender,
      "HTTP_X_BSV_NONCE" => nonce,
      "HTTP_X_BSV_TIME" => time,
      "HTTP_X_BSV_VOUT" => vout
    }.merge(overrides)
  end

  # ---------------------------------------------------------------------------
  # §2: Server's 402 Response
  # ---------------------------------------------------------------------------
  describe "challenge_headers" do
    let(:headers) { gateway.challenge_headers(mock_request, route) }

    it "returns exactly x-bsv-sats and x-bsv-server" do
      expect(headers.keys).to contain_exactly("x-bsv-sats", "x-bsv-server")
    end

    it "sets x-bsv-sats to the route amount as a string" do
      expect(headers["x-bsv-sats"]).to eq("1000")
    end

    it "sets x-bsv-server to the server identity public key" do
      expect(headers["x-bsv-server"]).to eq(server_identity_key)
    end

    it "accepts wallets whose get_public_key returns a bare string" do
      bare_wallet = double("wallet")
      allow(bare_wallet).to receive(:get_public_key).with(identity_key: true).and_return(server_identity_key)
      bare_gateway = described_class.new(wallet: bare_wallet, txid_store: txid_store)
      expect(bare_gateway.challenge_headers(mock_request, route)["x-bsv-server"]).to eq(server_identity_key)
    end
  end

  describe "proof_header_names" do
    it "returns x-bsv-beef" do
      expect(gateway.proof_header_names).to eq(["x-bsv-beef"])
    end
  end

  # ---------------------------------------------------------------------------
  # §5: Server Payment Validation
  # ---------------------------------------------------------------------------
  describe "settle!" do
    let(:transaction) { build_payment_tx(amount: 1000) }
    let(:beef_b64) { build_beef_b64(transaction) }

    context "happy path" do
      let(:request) { mock_request(paid_request_env(beef_b64: beef_b64)) }

      it "returns a SettlementResult with txid and network" do
        result = gateway.settle!("x-bsv-beef", nil, request, route)
        expect(result).to be_a(X402::SettlementResult)
        expect(result.txid).to eq(transaction.txid_hex)
        expect(result.network).to eq("bsv:mainnet")
      end

      it "includes x-bsv-payment-satoshis-paid receipt header" do
        result = gateway.settle!("x-bsv-beef", nil, request, route)
        expect(result.receipt_headers["x-bsv-payment-satoshis-paid"]).to eq("1000")
      end

      it "calls wallet.internalize_action with the correct payment remittance" do
        expected_time_str = request.env["HTTP_X_BSV_TIME"]
        expected_suffix = Base64.strict_encode64(expected_time_str)

        gateway.settle!("x-bsv-beef", nil, request, route)

        expect(wallet).to have_received(:internalize_action).with(
          hash_including(
            tx: kind_of(Array),
            description: "BRC-121 payment",
            outputs: [hash_including(
              output_index: 0,
              protocol: "wallet payment",
              payment_remittance: hash_including(
                derivation_prefix: request.env["HTTP_X_BSV_NONCE"],
                derivation_suffix: expected_suffix,
                sender_identity_key: client_identity_key
              )
            )]
          )
        )
      end
    end

    # §5 step 1: missing headers → 402
    context "missing client headers" do
      it "rejects when x-bsv-beef is missing" do
        env = paid_request_env(beef_b64: beef_b64)
        env.delete("HTTP_X_BSV_BEEF")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(402)
            expect(e.reason).to include("x-bsv-beef")
          }
      end

      %w[x-bsv-sender x-bsv-nonce x-bsv-time x-bsv-vout].each do |header|
        it "rejects when #{header} is missing" do
          env = paid_request_env(beef_b64: beef_b64)
          env.delete("HTTP_#{header.upcase.tr("-", "_")}")
          expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
            .to raise_error(X402::VerificationError) { |e|
              expect(e.status).to eq(402)
              expect(e.reason).to include(header)
            }
        end
      end

      it "rejects when a header is an empty string" do
        env = paid_request_env(beef_b64: beef_b64, overrides: { "HTTP_X_BSV_SENDER" => "" })
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError)
      end
    end

    # Invalid sender identity key format
    context "invalid x-bsv-sender" do
      it "rejects when sender is not a compressed pubkey hex" do
        env = paid_request_env(beef_b64: beef_b64, sender: "not-a-pubkey")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
            expect(e.reason).to include("x-bsv-sender")
          }
      end
    end

    # Nonce format (security hardening — reject before wallet call)
    context "invalid x-bsv-nonce" do
      it "rejects a nonce with non-base64 characters" do
        env = paid_request_env(beef_b64: beef_b64, nonce: "not$valid!base64")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
            expect(e.reason).to include("x-bsv-nonce")
          }
      end

      it "rejects a nonce that exceeds the length cap" do
        env = paid_request_env(beef_b64: beef_b64, nonce: "A" * 200)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
          }
      end

      it "accepts a standard base64 nonce with padding" do
        env = paid_request_env(beef_b64: beef_b64, nonce: "abc123AB==")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }.not_to raise_error
      end
    end

    # §5 step 2: x-bsv-time must be within 30 seconds of server clock
    context "timestamp freshness (§5 step 2)" do
      it "accepts a timestamp within the 30s window" do
        time_ms = (Time.now.to_f * 1000).to_i - 10_000
        env = paid_request_env(beef_b64: beef_b64, time: time_ms.to_s)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }.not_to raise_error
      end

      it "rejects a stale timestamp (more than 30s in the past)" do
        time_ms = (Time.now.to_f * 1000).to_i - 60_000
        env = paid_request_env(beef_b64: beef_b64, time: time_ms.to_s)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(402)
            expect(e.reason).to include("freshness")
          }
      end

      it "rejects a future timestamp (more than 30s in the future)" do
        time_ms = (Time.now.to_f * 1000).to_i + 60_000
        env = paid_request_env(beef_b64: beef_b64, time: time_ms.to_s)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError)
      end

      it "rejects a non-numeric timestamp" do
        env = paid_request_env(beef_b64: beef_b64, time: "not-a-number")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
          }
      end
    end

    # Output index / vout parsing
    context "x-bsv-vout" do
      it "rejects a non-numeric vout" do
        env = paid_request_env(beef_b64: beef_b64, vout: "abc")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
          }
      end

      it "rejects an out-of-range vout" do
        env = paid_request_env(beef_b64: beef_b64, vout: "99")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
            expect(e.reason).to include("out of range")
          }
      end
    end

    # Insufficient payment
    context "insufficient payment" do
      it "rejects a payment output below the required amount" do
        low_tx = build_payment_tx(amount: 500)
        env = paid_request_env(beef_b64: build_beef_b64(low_tx))
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(402)
            expect(e.reason).to include("insufficient")
          }
      end
    end

    # Malformed BEEF
    context "malformed BEEF" do
      it "rejects invalid base64 in x-bsv-beef" do
        env = paid_request_env(beef_b64: "not-base64!!!")
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
          }
      end

      it "rejects unparseable BEEF bytes" do
        env = paid_request_env(beef_b64: Base64.strict_encode64("garbage"))
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(400)
          }
      end
    end

    # §5 step 5: replay protection (our TxidStore substitute for wallet isMerge)
    context "replay protection" do
      it "rejects a replayed txid on the second settlement attempt" do
        env = paid_request_env(beef_b64: beef_b64)
        gateway.settle!("x-bsv-beef", nil, mock_request(env), route)

        # Second attempt with same tx but a fresh timestamp
        env2 = paid_request_env(beef_b64: beef_b64)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env2), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(402)
            expect(e.reason).to include("replay")
          }
      end
    end

    # Wallet internalisation failure
    context "wallet internalize_action failure" do
      it "raises VerificationError(402) when wallet raises" do
        allow(wallet).to receive(:internalize_action).and_raise(StandardError, "wallet broken")
        env = paid_request_env(beef_b64: beef_b64)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.status).to eq(402)
            expect(e.reason).to include("internalisation")
          }
      end

      it "does not leak the wallet exception message in the HTTP error" do
        allow(wallet).to receive(:internalize_action).and_raise(
          StandardError, "internal path /var/lib/wallets/secret.json: permission denied"
        )
        env = paid_request_env(beef_b64: beef_b64)
        expect { gateway.settle!("x-bsv-beef", nil, mock_request(env), route) }
          .to raise_error(X402::VerificationError) { |e|
            expect(e.reason).not_to include("/var/lib")
            expect(e.reason).not_to include("permission denied")
            expect(e.reason).to eq("payment internalisation failed")
          }
      end
    end
  end
end
