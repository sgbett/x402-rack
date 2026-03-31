# Ecosystem

## x402 Implementations

Three x402 ecosystems exist with different conventions. Our middleware supports all of them via the multi-gateway dispatch model.

### Coinbase x402 v2 (broad ecosystem)

- **Headers**: `Payment-Required` / `Payment-Signature` / `Payment-Response`
- **Flow**: client signs authorisation → facilitator broadcasts (verify → serve → settle)
- **Replay protection**: chain-native (EIP-712 nonces, Solana blockhash)
- **Request binding**: resource URL only (no method/path/query hash)
- **Multi-chain**: `accepts` array for multi-chain/multi-scheme negotiation
- **Spec**: https://docs.x402.org
- **Our PR**: https://github.com/coinbase/x402/pull/1844 (BSV scheme spec)

### Merkleworks x402 (BSV-specific)

- **Headers**: `X402-Challenge` / `X402-Proof`
- **Flow**: client broadcasts → server checks mempool (proof-of-payment)
- **Replay protection**: 1-sat nonce UTXO (single-spend at consensus layer)
- **Request binding**: strong (method, path, query, headers hash, body hash)
- **Spec**: https://github.com/ruidasilva/merkleworks-x402-spec
- **Reference impl**: https://github.com/merkleworks/x402-bsv

### BRC-105 (BSV Association BRC)

- **Headers**: `x-bsv-payment-version` / `x-bsv-payment-satoshis-required` / `x-bsv-payment-derivation-prefix` / `x-bsv-payment`
- **Flow**: authenticated (BRC-103/104) payment with derivation-based unique addresses
- **Replay protection**: server-tracked derivation prefixes (server-side state)
- **Identity**: requires BRC-103 mutual authentication (but could work without — see below)
- **Spec**: https://github.com/bitcoin-sv/BRCs/blob/master/payments/0105.md

## Header Namespace Reservations

| Namespace | Ecosystem |
|-----------|-----------|
| `Payment-*` | Coinbase v2 / our PayGateway |
| `X402-*` | Merkleworks / our ProofGateway |
| `x-bsv-*` | BRC-105 / BSV Association |

These namespaces must not overlap. When designing new headers or gateway types, check which namespace the target ecosystem uses.

## Our Position

Our PayGateway implements the Coinbase v2 header spec with BSV as the settlement network. This makes BSV a first-class citizen in the broader x402 ecosystem — any Coinbase-compatible server or client can interoperate with us.

We also support merkleworks via a separate ProofGateway that uses the `X402-*` headers.

Our BRC105Gateway implements the BSV Association's native payment protocol using `x-bsv-*` headers, enabling interoperability with BRC-100 wallets and the broader BSV ecosystem tooling.

Coinbase will likely gatekeep BSV from their ecosystem — our conformance is about making it easy for others to integrate BSV as a supported network.

## BRC-105: Standalone and Authenticated Modes

BRC-105 assumes BRC-103/104 mutual authentication, but `BRC105Gateway` supports both modes:

### Standalone mode (no BRC-103)

The gateway advertises its identity key in the `x-bsv-payment-identity-key` challenge header. The client uses this for BRC-29 key derivation. Counterparty is `"anyone"` — anonymous payments similar to PayGateway but using BSV-native headers.

- No handshake required
- Transport security handled by TLS
- Replay protection via server-tracked derivation prefixes

### Authenticated mode (with BRC-103 middleware)

When BRC-103 middleware is present upstream in the Rack stack, the gateway reads the client's authenticated identity key from `env['brc103.identity_key']` and uses it as the BRC-29 derivation counterparty. The identity key challenge header is omitted (the client already has the server's key from the BRC-103 handshake).

- Full BRC-105 compliance
- Payment bound to authenticated identity
- Stronger replay protection (session nonces + prefix tracking)

The gateway detects the mode automatically — no configuration change required. This allows composing `BRC103Middleware + BRC105Gateway` for the full authenticated flow, or using `BRC105Gateway` alone for the simpler anonymous path.

## Related Projects

- **x402-rack** (this gem): server-side Rack middleware
- **bsv-x402** (npm): client-side fetch wrapper ([sgbett/bsv-x402](https://github.com/sgbett/bsv-x402))
- **bsv-sdk** (gem): BSV primitives — keys, transactions, scripts, ARC
- **bsv-wallet** (gem): BRC-100 wallet interface
- **BSV Browser**: BRC-100 wallet with `window.CWI` ([bsv-blockchain/bsv-browser](https://github.com/bsv-blockchain/bsv-browser))
- **402index.io**: x402 endpoint aggregator with payment flow examples
