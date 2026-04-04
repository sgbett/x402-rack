# BSV-proof Scheme (merkleworks x402)

!!! danger "Experimental — not production-ready"
    The ProofGateway implementation is incomplete and under active development.
    The nonce provider interface, Profile B provenance verification, and mempool
    checking behaviour may change without notice. **Do not use in production.**
    For production BSV payments, use [BSV-pay](bsv-pay.md) (PayGateway) or
    [BRC-105](brc-105.md) (BRC105Gateway).

Client broadcasts, server checks mempool. Proof-of-payment model. Nonce-bound with request binding.

## Headers

| Direction | Header | Content |
|-----------|--------|---------|
| Server → Client | `X402-Challenge` | base64url(challenge JSON) |
| Client → Server | `X402-Proof` | base64url(proof JSON) |

## Profiles

### Profile A (no partial template)

The challenge includes nonce UTXO metadata only. The client must construct the entire transaction including the nonce input. No cryptographic proof of nonce provenance.

Suitable for deployments using an external treasury service that returns bare UTXO references.

### Profile B (treasury-signed template) — recommended

The **treasury** (via the `nonce_provider` callable) builds and signs a partial template. The gateway receives it and appends the OP_RETURN request binding:

- Input 0: nonce UTXO, signed with `SIGHASH_SINGLE | ANYONECANPAY | FORKID` (`0xC3`)
- Output 0: payment (committed by the treasury's signature)
- Output 1: OP_RETURN binding (appended by the gateway after receiving the template)

The gateway never holds a private key. Profile B is detected from the presence of `partial_tx` in the provider response.

The client extends the template by adding funding inputs. The `0xC3` signature proves the treasury issued the nonce — this is the provenance guarantee.

The template is included in the challenge as `partial_tx_b64` (base64-encoded), excluded from the canonical challenge hash (merkleworks spec compliance).

## Challenge (merkleworks JSON)

```json
{
  "version": 1,
  "scheme": "bsv-tx-v1",
  "domain": "api.example.com",
  "method": "GET",
  "path": "/weather",
  "query": "city=lisbon",
  "req_headers_sha256": "...",
  "req_body_sha256": "...",
  "amount_sats": 50,
  "payee_locking_script_hex": "76a914...88ac",
  "nonce_txid": "bb...cc",
  "nonce_vout": 0,
  "nonce_satoshis": 1,
  "nonce_locking_script_hex": "76a914...88ac",
  "expires_at": 1700000300,
  "partial_tx_b64": "<base64 of pre-signed template>"
}
```

The `partial_tx_b64` field is present only in Profile B and is **not part of the canonical hash** (`sha256_hex` excludes it).

## Settlement Flow

1. Decode `X402-Proof` header (base64url → proof JSON)
2. Reconstruct challenge from echoed `X402-Challenge` header
3. Protocol checks: version, scheme, challenge hash, request binding, expiry
4. Decode raw tx from proof
5. Verify nonce UTXO at input index 0 (not just "any input")
6. **Profile B**: verify nonce signature via full P2PKH script verification (`verify_input(0)`)
7. Verify payment output against server's own payee address
8. Check mempool visibility via ARC (`status(txid)`)
9. Return settlement result

### Why Client Broadcasts

Per Rui at merkleworks: broadcasting is settlement, not authorisation. If the server broadcasts, it takes on transaction submission responsibility, retry/reconciliation logic, and mempool interaction state — pushing it towards a stateful payment processor. Client-side broadcast keeps the server stateless and HTTP authorisation cleanly decoupled from network settlement.

## Nonce UTXOs

- 1-satoshi P2PKH outputs issued by the treasury
- Single-spend (UTXO consumption) provides replay protection + challenge binding
- Timelock return: unused nonces auto-return via timelocked script path (treasury concern)
- The blockchain is the state — no server-side nonce pools, no lease tables

See [operations/treasury.md](../operations/treasury.md) for nonce lifecycle.

## Nonce Provider Interface

The `nonce_provider` is a callable that receives `(rack_request, payee:, amount:)` and returns a hash:

```ruby
# Profile A — bare UTXO metadata
provider = ->(request, payee:, amount:) {
  { txid: "...", vout: 0, satoshis: 1, locking_script_hex: "76a914...88ac" }
}

# Profile B — includes pre-signed partial template
provider = ->(request, payee:, amount:) {
  tx = build_and_sign_template(payee: payee, amount: amount)
  { txid: "...", vout: 0, satoshis: 1, locking_script_hex: "76a914...88ac",
    partial_tx: tx.to_binary }
}
```

The presence of `:partial_tx` in the response triggers Profile B behaviour. The gateway appends the OP_RETURN after deserialising the template.

## Infrastructure Required

Trust boundary: `[(X)+(B)] <-> [(T)]` — the server (x402-rack + BSV gateway) never holds keys; the treasury is a separate trust domain.

- **Treasury** (`nonce_provider`): mints nonce UTXOs, holds keys, signs templates (Profile B)
- **ARC**: mempool queries (`status(txid)`)
