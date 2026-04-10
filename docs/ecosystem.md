# Ecosystem

## x402 Implementations

Four BSV payment schemes are supported via the multi-gateway dispatch model.

### Coinbase x402 v2 (broad ecosystem)

- **Headers**: `Payment-Required` / `Payment-Signature` / `Payment-Response`
- **Flow**: client signs authorisation → facilitator broadcasts (verify → serve → settle)
- **Replay protection**: chain-native (EIP-712 nonces, Solana blockhash)
- **Request binding**: resource URL only (no method/path/query hash)
- **Multi-chain**: `accepts` array for multi-chain/multi-scheme negotiation
- **Spec**: https://docs.x402.org
- **Our PR**: https://github.com/x402-foundation/x402/pull/1844 (BSV scheme spec)

### BRC-121 (Simple 402 Payments)

- **Headers**: `x-bsv-sats` / `x-bsv-server` / `x-bsv-beef` / `x-bsv-sender` / `x-bsv-nonce` / `x-bsv-time` / `x-bsv-vout`
- **Flow**: stateless; client builds BRC-29 payment in one round trip with a timestamp-suffixed derivation
- **Replay protection**: 30s timestamp freshness window + wallet `isMerge` (or `TxidStore` fallback in Ruby)
- **Identity**: no BRC-103 required; client identity is carried in the `x-bsv-sender` header and used as the BRC-29 counterparty
- **Spec**: https://github.com/bitcoin-sv/BRCs/blob/master/payments/0121.md

### BRC-105 (HTTP Service Monetization Framework)

- **Headers**: `x-bsv-payment-version` / `x-bsv-payment-satoshis-required` / `x-bsv-payment-derivation-prefix` / `x-bsv-payment`
- **Flow**: authenticated (BRC-103/104) payment with server-generated derivation prefix
- **Replay protection**: server-tracked derivation prefixes (PrefixStore)
- **Identity**: **requires** BRC-103 mutual authentication per spec §3/§5.1/§7.1
- **Status**: transitional in x402-rack — accepts the client identity key via HTTP header as a stopgap until Ruby BRC-103 middleware lands
- **Spec**: https://github.com/bitcoin-sv/BRCs/blob/master/payments/0105.md

### Merkleworks x402 (BSV-specific)

- **Headers**: `X402-Challenge` / `X402-Proof`
- **Flow**: client broadcasts → server checks mempool (proof-of-payment)
- **Replay protection**: 1-sat nonce UTXO (single-spend at consensus layer)
- **Request binding**: strong (method, path, query, headers hash, body hash)
- **Status**: experimental
- **Spec**: https://github.com/ruidasilva/merkleworks-x402-spec
- **Reference impl**: https://github.com/merkleworks/x402-bsv

## Header Namespace Reservations

| Namespace | Ecosystem |
|-----------|-----------|
| `Payment-*` | Coinbase v2 / our PayGateway |
| `X402-*` | Merkleworks / our ProofGateway |
| `x-bsv-payment-*` | BRC-105 / BSV Association |
| `x-bsv-sats`, `x-bsv-server`, `x-bsv-beef`, `x-bsv-sender`, `x-bsv-nonce`, `x-bsv-time`, `x-bsv-vout` | BRC-121 / BSV Association |

These namespaces must not overlap. When designing new headers or gateway types, check which namespace the target ecosystem uses. Note that BRC-105 and BRC-121 both use the `x-bsv-*` prefix but with disjoint header sets — they can coexist on the same server.

## Our Position

**PayGateway** implements the Coinbase v2 header spec with BSV as the settlement network — BSV as a first-class citizen in the broader x402 ecosystem.

**BRC121Gateway** implements the BSV Association's simple HTTP payment protocol — stateless, BRC-100 wallet-native, zero config. The most direct path to a working BSV-native x402 server.

**BRC105Gateway** implements the BSV Association's authenticated payment protocol — requires BRC-103 middleware per spec. Transitional in x402-rack today; clients that send `x-bsv-auth-identity-key` as an HTTP header work via a documented stopgap until a Ruby BRC-103 middleware lands.

**ProofGateway** implements merkleworks x402 — experimental; kept for compatibility with the merkleworks ecosystem.

PayGateway and BRC121Gateway are auto-enabled when you set `config.wallet = ...`. The other two are opt-in via `config.enable :brc105_gateway` or `:proof_gateway`.

## Related Projects

- **x402-rack** (this gem): server-side Rack middleware
- **bsv-x402** (npm): client-side fetch wrapper ([sgbett/bsv-x402](https://github.com/sgbett/bsv-x402))
- **bsv-sdk** (gem): BSV primitives — keys, transactions, scripts, ARC
- **bsv-wallet** (gem): BRC-100 wallet interface
- **BSV Browser**: BRC-100 wallet with `window.CWI` ([bsv-blockchain/bsv-browser](https://github.com/bsv-blockchain/bsv-browser))
- **402index.io**: x402 endpoint aggregator with payment flow examples
