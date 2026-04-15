# Architecture

## Middleware as Dispatcher (`X402::Middleware`)

The Rack middleware is a **pure dispatcher** — the gatekeeper. It has no blockchain knowledge. It:

1. Matches incoming requests against protected routes
2. Polls each configured gateway for challenge headers, returns all of them in the 402 response
3. Checks which proof/payment header the client sent, dispatches to the matching gateway
4. The gateway returns allow/deny — the middleware serves or rejects accordingly

The middleware never decodes transactions, checks mempool, broadcasts, or interacts with any blockchain network. It manages HTTP headers, route matching, and dispatch.

**The gatekeeper MUST NOT sign transactions or hold private keys.**

## Gateways

Gateways are pluggable backends that handle chain-specific settlement. They delegate key management and signing to external providers (e.g. the treasury via `nonce_provider`). Each gateway:

- Builds challenge data (including partial transaction templates)
- Verifies and settles proofs
- Interacts with ARC and/or a treasury service via the BSV wallet

### Gateway Interface

```ruby
#   #challenge_headers(rack_request, route) → Hash
#   #proof_header_names → Array<String>
#   #settle!(header_name, proof_payload, rack_request, route) → result
```

The boundary test: could someone write `X402::EVM::Gateway` implementing this interface without touching `lib/x402/`? If yes, the separation is correct.

### Built-in Gateways

- **`X402::BSV::PayGateway`** — Coinbase v2 headers, server broadcasts via ARC. See [schemes/bsv-pay.md](schemes/bsv-pay.md).
- **`X402::BSV::BRC121Gateway`** — BRC-121 simple payments, stateless, BRC-100 wallet-native. See [schemes/brc-121.md](schemes/brc-121.md).
- **`X402::BSV::BRC105Gateway`** — BRC-105 authenticated payments, BRC-29 derived addresses, AtomicBEEF transactions. See [schemes/brc-105.md](schemes/brc-105.md).
- **`X402::BSV::ProofGateway`** — merkleworks headers, client broadcasts, server checks mempool. See [schemes/bsv-proof.md](schemes/bsv-proof.md).

## Payment Content Negotiation

Different x402 ecosystems use different HTTP headers. A server can send **multiple challenge headers** simultaneously — the client picks the one it can satisfy.

| Scheme | Challenge headers | Proof header | Receipt header |
|--------|------------------|--------------|----------------|
| BSV-pay (ours) | `Payment-Required` | `Payment-Signature` | `Payment-Response` |
| BRC-121 (BSV Association) | `x-bsv-payment-satoshis-required`, `x-bsv-payment-version` | `x-bsv-beef` | `x-bsv-payment-satoshis-paid` |
| BRC-105 (BSV Association) | `x-bsv-payment-satoshis-required`, `x-bsv-payment-derivation-prefix`, `x-bsv-payment-identity-key`* | `x-bsv-payment` | `x-bsv-payment-result` |
| BSV-proof (merkleworks) | `X402-Challenge` | `X402-Proof` | — |

\* `x-bsv-payment-identity-key` is omitted when BRC-103 middleware is present upstream.

Header namespaces are reserved per ecosystem:
- `Payment-*` — Coinbase v2 / our PayGateway
- `x-bsv-*` — BRC-121 and BRC-105 / BSV Association (our BRC121Gateway and BRC105Gateway)
- `X402-*` — merkleworks / our ProofGateway

## Transaction Models

### Template-based (PayGateway, ProofGateway)

Both template-based gateways produce **partial transaction templates** that the client extends by adding funding inputs (and optionally change outputs).

**Base behaviour** (`X402::BSV::Gateway`): build a partial tx with the payment output (amount to payee) and an OP_RETURN request binding output.

**ProofGateway override**: prepends the nonce UTXO input at index 0, signed with `SIGHASH_SINGLE | ANYONECANPAY | FORKID (0xC3)`. This locks the payment output (output 0) while allowing the client to append inputs and outputs freely.

**PayGateway**: inherits the base behaviour. Payment output + OP_RETURN binding, no nonce.

The client's job is identical for template-based gateways: add funding inputs, sign, and either broadcast (BSV-proof) or hand to the server (BSV-pay).

### Derivation-based (BRC105Gateway)

BRC105Gateway uses a fundamentally different approach — **no partial transaction template**. Instead:

1. The server advertises a derivation prefix (random nonce) and its identity key
2. The client derives a unique payment address using BRC-29 (BRC-42 key derivation with protocol ID `[2, "3241645161d8"]` and key ID `"#{prefix} #{suffix}"`)
3. The client builds the entire transaction independently, paying to the derived address
4. The server re-derives the expected address and verifies the payment output

This eliminates the need for OP_RETURN binding, payTo HMAC, or any shared transaction state. BRC105Gateway does not inherit from `Gateway` — it uses composition via `KeyDeriver`.

### Request Binding via OP_RETURN

```
Output 0: payment (amount to payee)
Output 1: OP_RETURN "x402" <SHA256(method + path + query)>
```

The `x402` protocol tag makes payments discoverable on-chain. The SHA-256 hash binds the payment to the specific HTTP request. Configurable strict/permissive mode.

### Why 0xC3 for the Nonce Signature

`SIGHASH_SINGLE | ANYONECANPAY | FORKID`:
- `SIGHASH_SINGLE`: commits only to `output[input_index]` — the nonce at input 0 protects only output 0 (the payment)
- `ANYONECANPAY`: excludes other inputs — funding and fee inputs can be appended freely
- `FORKID`: BSV fork ID flag (required)

Using `0xC1` (`SIGHASH_ALL | ANYONECANPAY`) would commit to ALL outputs, breaking extensibility.

## Component Boundaries

| Component | Responsibility | Keys? |
|-----------|---------------|-------|
| **Gatekeeper** (`X402::Middleware`) | HTTP dispatch, route matching | No — MUST NOT hold keys |
| **Gateway** (`X402::BSV::*Gateway`) | Challenge templates, settlement, ARC interaction | Via wallet |
| **BSV Wallet** (`bsv-wallet` gem) | Key management, UTXO tracking, signing | Yes — the security boundary |
| **Treasury** (wallet role) | Mints nonce UTXOs, signs templates | Via wallet's nonce basket |
| **Delegator** (separate service) | Adds fee inputs, signs only fee inputs | Yes — but not our concern |
| **Client** (browser + CWI wallet) | Extends template, signs funding inputs | Yes — client's wallet |

### Dependency Chain

```
x402-rack (no keys, no wallet dependency in middleware)
  └── X402::BSV::*Gateway → bsv-wallet (BRC-100 interface)
                                └── bsv-sdk (primitives)
```

The middleware itself has no dependency on `bsv-wallet` or `bsv-sdk`. Only the gateway classes do.
