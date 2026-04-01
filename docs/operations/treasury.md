# Treasury

The treasury mints and manages 1-satoshi nonce UTXOs for the ProofGateway. It is not needed for PayGateway (which uses ARC as the replay gate).

## Nonce UTXO Lifecycle

### Minting

The treasury creates 1-sat P2PKH outputs locked to the nonce key. Each output becomes a nonce for one challenge.

### Issuance

When the ProofGateway builds a challenge, it requests a nonce from the treasury (via the `nonce_provider` callable). The nonce UTXO details (txid, vout, satoshis, locking_script_hex) are included in the challenge.

In Profile B, the treasury signs the nonce input with `0xC3` and returns the pre-signed template (as `partial_tx` binary) to the gateway. The gateway appends the OP_RETURN and includes the template in the challenge.

### Spending

The client spends the nonce UTXO as input 0 of the payment transaction. Bitcoin's single-spend guarantee ensures the nonce can only be used once — this is the replay protection mechanism.

### Expiry and Reclamation

Unused nonces (challenges that were issued but never answered) need reclamation. The approach:

- Nonce UTXOs carry a **timelocked return path** — if not spent within the timelock window, the funds auto-return to the treasury's source address
- Script structure: `OP_IF <spend_path> OP_ELSE <timeout> OP_CSV OP_DROP <treasury_pubkey> OP_CHECKSIG OP_ENDIF`
- After the timelock expires, miners may consolidate these UTXOs for free (they're incentivised to reduce the UTXO set)

**The blockchain is the state.** No server-side nonce pools, no lease tables, no release callbacks.

## Wallet Integration

The treasury is a **role** the `bsv-wallet` gem plays, using the `x402-nonces` basket:

| Operation | BRC-100 Method |
|-----------|---------------|
| Mint nonces | `createAction` |
| List available nonces | `listOutputs` (basket: `x402-nonces`) |
| Sign templates | Uses the nonce key (held by wallet) |

## Scaling

Nonce provision can be horizontally scaled:

- Multiple treasury instances can mint UTXOs independently
- Each instance manages its own nonce pool
- The nonce key can be shared (or derived) across instances
- Minting 1-sat UTXOs is fast and cheap (1 sat per nonce + negligible fee)

The treasury is not on the critical path for settlement — it only participates at challenge time. Settlement just checks mempool.

## Current Implementation

The `nonce_provider` is a callable injected into ProofGateway. It receives `payee:` and `amount:` kwargs so the treasury can build the template:

```ruby
# Profile A — bare UTXO metadata
nonce_provider = ->(request, payee:, amount:) {
  { txid: "...", vout: 0, satoshis: 1, locking_script_hex: "76a914...88ac" }
}

# Profile B — treasury builds and signs the template
nonce_provider = ->(request, payee:, amount:) {
  tx = build_and_sign_template(payee: payee, amount: amount)
  { txid: "...", vout: 0, satoshis: 1, locking_script_hex: "76a914...88ac",
    partial_tx: tx.to_binary }
}
```

Full wallet-backed treasury integration (basket-managed nonce pool, automatic minting, timelock expiry) is tracked in [bsv-ruby-sdk#196](https://github.com/sgbett/bsv-ruby-sdk/issues/196).
