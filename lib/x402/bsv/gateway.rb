# frozen_string_literal: true

require "openssl"
require "securerandom"
require "bsv-sdk"

module X402
  module BSV
    # Base gateway class for BSV settlement schemes.
    #
    # Builds partial transaction templates containing a payment output.
    # The OP_RETURN request binding is NOT included in the template —
    # it must be appended last by the client to preserve SIGHASH_SINGLE
    # index alignment (input N → output N for each signer).
    #
    # When a wallet is provided, each challenge derives a unique payee
    # address via BRC-29 key derivation, preventing address reuse.
    class Gateway
      # BRC-29 protocol ID — shared with BRC-105 and BRC-121 so all
      # gateways derive keys the wallet can spend via the same scheme.
      BRC29_PROTOCOL_ID = [2, "3241645161d8"].freeze

      attr_reader :payee_locking_script_hex

      # @param payee_locking_script_hex [String, nil] static payee script hex;
      #   falls back to X402.configuration.payee_locking_script_hex if nil.
      #   Ignored when wallet is provided (derived addresses used instead).
      # @param wallet [BSV::Wallet::ProtoWallet, nil] wallet for key derivation.
      #   When provided, each challenge gets a unique derived payee address.
      # @param challenge_secret [String, nil] HMAC secret for signing challenge data.
      #   Auto-generated if not provided. Used to verify payTo hasn't been tampered with.
      def initialize(payee_locking_script_hex: nil, wallet: nil, challenge_secret: nil)
        @payee_locking_script_hex = payee_locking_script_hex
        @wallet = wallet
        @challenge_secret = challenge_secret || SecureRandom.hex(32)
      end

      # Build a partial transaction template for the given route.
      #
      # Output 0: payment (amount_sats to payee locking script)
      #
      # The OP_RETURN is NOT included — the client appends it last so that
      # SIGHASH_SINGLE index alignment is preserved (each signer's input
      # index matches their change output index).
      #
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [Array(BSV::Transaction::Transaction, String, String, String)]
      #   transaction, payee script hex, derivation prefix, derivation suffix
      def build_template(_rack_request, required_sats)
        tx = ::BSV::Transaction::Transaction.new

        # Output 0: payment (unique address if wallet configured, static otherwise)
        payee_hex, prefix, suffix = derive_payee_hex
        payee_script = ::BSV::Script::Script.from_hex(payee_hex)
        tx.add_output(::BSV::Transaction::TransactionOutput.new(
                        satoshis: required_sats,
                        locking_script: payee_script
                      ))

        [tx, payee_hex, prefix, suffix]
      end

      # Compute the SHA-256 hash used for request binding.
      #
      # @param rack_request [Rack::Request]
      # @return [String] 32-byte binary hash
      def request_binding_hash(rack_request)
        data = "#{rack_request.request_method}#{rack_request.path_info}"
        data += rack_request.query_string unless rack_request.query_string.empty?
        OpenSSL::Digest::SHA256.digest(data)
      end

      private

      # Derive a unique payee locking script hex for this challenge.
      # Uses BRC-29 key derivation when a wallet is configured.
      # Falls back to the static payee_locking_script_hex otherwise.
      #
      # @return [Array(String, String|nil, String|nil)] payee hex, derivation prefix, derivation suffix
      def derive_payee_hex
        if @wallet
          derive_unique_payee_hex
        else
          [resolve_static_payee_hex, nil, nil]
        end
      end

      # Derive a unique payee address using BRC-29 key derivation.
      #
      # BRC-29 invoice number: "2-3241645161d8-<prefix> <suffix>"
      # The prefix is random per payment; the suffix is fixed ("0") since
      # PayGateway uses one output per payment. The wallet can later derive
      # the matching private key using the same prefix/suffix pair.
      def derive_unique_payee_hex
        prefix = Base64.strict_encode64(SecureRandom.random_bytes(16))
        suffix = Base64.strict_encode64("0")
        key_id = "#{prefix} #{suffix}"
        result = @wallet.get_public_key({
                                          protocol_id: BRC29_PROTOCOL_ID,
                                          key_id: key_id,
                                          identity_key: false
                                        })
        pubkey = ::BSV::Primitives::PublicKey.from_hex(result[:public_key])
        h160 = pubkey.hash160.unpack1("H*")
        ["76a914#{h160}88ac", prefix, suffix]
      end

      def resolve_static_payee_hex
        hex = @payee_locking_script_hex || X402.configuration.payee_locking_script_hex
        raise X402::ConfigurationError, "payee_locking_script_hex is required" if hex.nil? || hex.empty?

        hex
      end

      # For settlement verification: parse a payee script from hex
      def payee_script_from_hex(hex)
        ::BSV::Script::Script.from_hex(hex)
      end

      # HMAC-sign the payTo field (and optional derivation params) to
      # prevent client tampering. The signature is included in the
      # challenge and verified at settlement.
      def sign_pay_to(pay_to_hex, prefix = nil, suffix = nil)
        data = if prefix
                 "#{pay_to_hex}:#{prefix}:#{suffix}"
               else
                 pay_to_hex
               end
        OpenSSL::HMAC.hexdigest("SHA256", @challenge_secret, data)
      end

      # Verify the payTo HMAC from an echoed challenge/accepted block.
      # Raises VerificationError if the signature doesn't match.
      def verify_pay_to_signature!(pay_to_hex, signature, prefix = nil, suffix = nil)
        if signature.nil?
          raise X402::VerificationError.new("payTo signature mismatch — possible tampering", status: 400)
        end

        expected = sign_pay_to(pay_to_hex, prefix, suffix)
        return if secure_compare(expected, signature)

        raise X402::VerificationError.new("payTo signature mismatch — possible tampering", status: 400)
      end

      # Constant-time string comparison to prevent timing attacks
      def secure_compare(left, right)
        return false unless left.bytesize == right.bytesize

        OpenSSL.fixed_length_secure_compare(left, right)
      end

      def build_op_return_script(binding_hash)
        # OP_FALSE OP_RETURN OP_PUSH4 "x402" OP_PUSH32 <32-byte binding hash>
        hex = "006a047834303220#{binding_hash.unpack1("H*")}"
        ::BSV::Script::Script.from_hex(hex)
      end
    end
  end
end
