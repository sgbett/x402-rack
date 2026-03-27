# frozen_string_literal: true

require "openssl"
require "bsv-sdk"

module X402
  module BSV
    # Base gateway class for BSV settlement schemes.
    #
    # Builds partial transaction templates containing a payment output
    # and an OP_RETURN request binding output. Subclasses override or
    # extend this to add scheme-specific behaviour (nonces, headers, settlement).
    class Gateway
      attr_reader :payee_locking_script_hex

      # @param payee_locking_script_hex [String, nil] payee script hex;
      #   falls back to X402.configuration.payee_locking_script_hex if nil
      def initialize(payee_locking_script_hex: nil)
        @payee_locking_script_hex = payee_locking_script_hex
      end

      # Build a partial transaction template for the given route.
      #
      # Output 0: payment (amount_sats to payee locking script)
      # Output 1: OP_RETURN request binding (SHA-256 of method + path + query)
      #
      # @param rack_request [Rack::Request]
      # @param route [X402::Configuration::Route]
      # @return [BSV::Transaction::Transaction]
      def build_template(rack_request, route)
        tx = ::BSV::Transaction::Transaction.new

        # Output 0: payment
        payee_script = resolve_payee_script
        tx.add_output(::BSV::Transaction::TransactionOutput.new(
                        satoshis: route.amount_sats,
                        locking_script: payee_script
                      ))

        # Output 1: OP_RETURN request binding
        binding_hash = request_binding_hash(rack_request)
        op_return_script = build_op_return_script(binding_hash)
        tx.add_output(::BSV::Transaction::TransactionOutput.new(
                        satoshis: 0,
                        locking_script: op_return_script
                      ))

        tx
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

      def resolve_payee_script
        hex = @payee_locking_script_hex || X402.configuration.payee_locking_script_hex
        raise X402::ConfigurationError, "payee_locking_script_hex is required" if hex.nil? || hex.empty?

        ::BSV::Script::Script.from_hex(hex)
      end

      def build_op_return_script(data)
        # OP_FALSE OP_RETURN OP_PUSH32 <32-byte hash>
        hex = "006a20#{data.unpack1("H*")}"
        ::BSV::Script::Script.from_hex(hex)
      end
    end
  end
end
