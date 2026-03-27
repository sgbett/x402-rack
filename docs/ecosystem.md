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

Coinbase will likely gatekeep BSV from their ecosystem — our conformance is about making it easy for others to integrate BSV as a supported network.

## BRC-105 Without Auth

BRC-105 assumes BRC-103/104 mutual authentication, but the payment mechanism can work without it:

- The derivation prefix nonce doesn't require identity — just a unique prefix per challenge
- Transport security is handled by TLS (BRC-104 itself says it "does not replace TLS")
- The server can use its own fixed public key for derivation without a BRC-103 handshake

A future `X402::BSV::BRC105Gateway` could operate in "no-auth" mode, reading `env['brc103.identity_key']` if present (enriched path) or using its own key if not (anonymous path).

## Related Projects

- **x402-rack** (this gem): server-side Rack middleware
- **bsv-x402** (npm): client-side fetch wrapper ([sgbett/bsv-x402](https://github.com/sgbett/bsv-x402))
- **bsv-sdk** (gem): BSV primitives — keys, transactions, scripts, ARC
- **bsv-wallet** (gem): BRC-100 wallet interface
- **BSV Browser**: BRC-100 wallet with `window.CWI` ([bsv-blockchain/bsv-browser](https://github.com/bsv-blockchain/bsv-browser))
- **402index.io**: x402 endpoint aggregator with payment flow examples
