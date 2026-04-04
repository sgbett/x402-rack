# BSV-pay Scheme

The default gateway. Direct peer-to-peer payment — client pays server, server broadcasts to the network.

## Description

Server broadcasts via ARC. Uses Coinbase v2 header spec. Minimal infrastructure — ARC only, no treasury, no nonces.

## Headers

| Direction | Header | Content |
|-----------|--------|---------|
| Server → Client | `Payment-Required` | base64(PaymentRequired JSON) |
| Client → Server | `Payment-Signature` | base64(PaymentPayload JSON) |
| Server → Client | `Payment-Response` | base64(SettlementResponse JSON) |

## Challenge

Coinbase v2 `PaymentRequired` structure with BSV in the `accepts` array:

```json
{
  "x402Version": 2,
  "resource": { "url": "/api/expensive" },
  "accepts": [
    {
      "scheme": "exact",
      "network": "bsv:mainnet",
      "amount": "100",
      "asset": "BSV",
      "payTo": "76a914...88ac",
      "maxTimeoutSeconds": 60,
      "extra": {
        "partialTx": "<base64 of partial tx template>",
        "payToSig": "<HMAC-SHA256 of payTo>"
      }
    }
  ]
}
```

### Progressive Enhancement

`extra.partialTx` carries the pre-built transaction template. Basic x402 v2 clients can ignore it and build from `payTo` + `amount`. BSV-aware clients extend the template directly.

### payToSig HMAC

The `payToSig` field is an HMAC-SHA256 of the `payTo` value, signed with a server-side secret. Prevents clients from substituting their own payee address. Verified at settlement before trusting `accepted.payTo`.

## Settlement Flow

1. Decode `Payment-Signature` header (base64 → PaymentPayload JSON)
2. Verify `accepted.network` matches `bsv:mainnet`
3. Verify `accepted.amount` meets route requirement
4. Verify `payToSig` HMAC (prevents payTo tampering)
5. Decode raw tx from `payload.rawtx`
6. Verify payment output (amount + payee)
7. Verify OP_RETURN request binding (strict or permissive mode)
8. Broadcast to ARC (`X-WaitFor: SEEN_ON_NETWORK`)
9. ARC 200 → return `Payment-Response`, serve resource
10. ARC error → relay to client

## Replay Protection

**No nonces needed.** ARC is the replay gate. Each transaction can only be accepted once — UTXO single-spend is enforced at the network layer. If a client submits the same tx twice, ARC rejects the second broadcast.

## ARC Configuration

- `arc_wait_for`: `SEEN_ON_NETWORK` (default) — tx has propagated to multiple nodes
- `arc_timeout`: 5 seconds (default) — returns 504 if ARC doesn't respond
- Both configurable per gateway instance

See [operations/performance.md](../operations/performance.md) for scaling considerations.

## Process Flow

See [process-flow/pay-gateway.md](../process-flow/pay-gateway.md) for sequence diagrams.
