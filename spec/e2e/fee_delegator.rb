# frozen_string_literal: true

# Simple fee delegator for e2e testing.
#
# Receives a partially-signed transaction (nonce signed by treasury,
# client inputs signed by client), adds fee-covering inputs from its
# own wallet, and signs only its own inputs.
class FeeDelegator
  DELEGATOR_SIGHASH = BSV::Transaction::Sighash::ALL_FORK_ID_ANYONE_CAN_PAY

  def initialize(private_key:, provider:)
    @key = private_key
    @provider = provider
    @locking_script = BSV::Script::Script.from_hex(
      "76a914#{@key.public_key.hash160.unpack1("H*")}88ac"
    )
  end

  # Add fee inputs to a partially-signed transaction.
  # Signs only the newly added inputs with 0xC1.
  #
  # @param transaction [BSV::Transaction::Transaction]
  # @param network [Symbol] :testnet or :mainnet
  # @return [BSV::Transaction::Transaction]
  def delegate(transaction, network: :testnet)
    existing_input_count = transaction.inputs.size

    add_fee_inputs(transaction, network)
    sign_new_inputs(transaction, existing_input_count)

    transaction
  end

  private

  def add_fee_inputs(transaction, network)
    address = @key.public_key.address(network: network)
    utxos = @provider.fetch_utxos(address)

    fee_needed = estimate_fee(transaction)
    funded = 0

    utxos.each do |utxo|
      break if funded >= fee_needed

      input = BSV::Transaction::TransactionInput.new(
        prev_tx_id: [utxo.tx_hash].pack("H*").reverse,
        prev_tx_out_index: utxo.tx_pos
      )
      input.source_satoshis = utxo.satoshis
      input.source_locking_script = @locking_script
      transaction.add_input(input)
      funded += utxo.satoshis
    end

    # No change output — the delegator absorbs the excess as fee.
    # Adding an output would invalidate the client's SIGHASH_ALL signature.
  end

  def sign_new_inputs(transaction, start_index)
    (start_index...transaction.inputs.size).each do |idx|
      transaction.sign(idx, @key, DELEGATOR_SIGHASH)
    end
  end

  def estimate_fee(transaction, satoshis_per_byte: 1)
    # Rough: each input ~148 bytes, each output ~34 bytes, overhead ~10
    # Add 1 extra input (the fee input we're about to add) + 1 extra output (change)
    input_bytes = (transaction.inputs.size + 1) * 148
    output_bytes = (transaction.outputs.size + 1) * 34
    ((input_bytes + output_bytes + 10) * satoshis_per_byte).ceil
  end
end
