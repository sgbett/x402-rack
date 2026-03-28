# frozen_string_literal: true

# Fee delegator for e2e testing.
#
# Receives a partially-signed transaction, adds fee-covering inputs
# with a change output, and signs only its own inputs with 0xC3.
#
# Signing convention:
#   Treasury:  0xC3 (input 0 → output 0: payment)
#   Client:    0xC3 (input 1 → output 1: client change)
#   Delegator: 0xC3 (input 2 → output 2: delegator change)
#   OP_RETURN: appended last by client, unsigned
class FeeDelegator
  # SIGHASH_SINGLE|ANYONECANPAY|FORKID — commits to own output only
  DELEGATOR_SIGHASH = BSV::Transaction::Sighash::SINGLE_FORK_ID_ANYONE_CAN_PAY

  def initialize(private_key:, provider:)
    @key = private_key
    @provider = provider
    @locking_script = BSV::Script::Script.from_hex(
      "76a914#{@key.public_key.hash160.unpack1("H*")}88ac"
    )
  end

  # Add fee input + change output, sign with 0xC3.
  #
  # @param transaction [BSV::Transaction::Transaction]
  # @param network [Symbol] :testnet or :mainnet
  # @return [BSV::Transaction::Transaction]
  def delegate(transaction, network: :testnet)
    fee_input_index = transaction.inputs.size

    add_fee_input(transaction, network)
    add_change_output(transaction)
    transaction.sign(fee_input_index, @key, DELEGATOR_SIGHASH)

    transaction
  end

  private

  def add_fee_input(transaction, network)
    address = @key.public_key.address(network: network)
    utxos = @provider.fetch_utxos(address)
    raise "no UTXOs available for fee delegation" if utxos.empty?

    # Pick the smallest UTXO that covers the estimated fee
    fee_needed = estimate_fee(transaction)
    utxo = utxos.select { |u| u.satoshis >= fee_needed }.min_by(&:satoshis)
    utxo ||= utxos.max_by(&:satoshis) # fallback to largest if none big enough

    @selected_utxo = utxo

    input = BSV::Transaction::TransactionInput.new(
      prev_tx_id: [utxo.tx_hash].pack("H*").reverse,
      prev_tx_out_index: utxo.tx_pos
    )
    input.source_satoshis = utxo.satoshis
    input.source_locking_script = @locking_script
    transaction.add_input(input)
  end

  def add_change_output(transaction)
    fee = estimate_fee(transaction)
    change = @selected_utxo.satoshis - fee
    change = 0 if change.negative?

    # Change output at the same index as the fee input (for 0xC3 alignment)
    transaction.add_output(BSV::Transaction::TransactionOutput.new(
                             satoshis: change,
                             locking_script: @locking_script
                           ))
  end

  def estimate_fee(transaction, satoshis_per_byte: 1)
    # Each input ~148 bytes, each output ~34 bytes, overhead ~10
    # Account for the fee input + change output + OP_RETURN we're about to add
    input_bytes = (transaction.inputs.size + 1) * 148
    output_bytes = (transaction.outputs.size + 2) * 34 # +2 for change + OP_RETURN
    ((input_bytes + output_bytes + 10) * satoshis_per_byte).ceil
  end
end
