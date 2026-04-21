# Architecture

## Core invariant

> **x402-rack serves content if and only if the payment transaction is confirmed on the BSV network.**

This is the one job. Each gateway enforces it according to its spec:

- **PayGateway** broadcasts the tx to ARC itself (x402 protocol — server settles).
- **BRC121Gateway** and **BRC105Gateway** verify the client's broadcast via `arc_client.status(txid)` — per BRC-121 §5 and BRC-105 §6.3, the client broadcasts.
- **ProofGateway** checks ARC status (client broadcasts first, per the merkleworks scheme).

All paths block the 200 until ARC confirms. Failures bifurcate cleanly:

- **402** — tx not on-chain, rejected, or invalid (client fault)
- **503** — ARC unreachable / 5xx / timeout (infrastructure fault)

See [schemes/brc-121.md](schemes/brc-121.md#on-chain-verification) and [schemes/brc-105.md](schemes/brc-105.md#on-chain-verification) for per-gateway specifics.

## Mental model: x402-rack is the checkout

The clearest way to understand x402-rack is to stop thinking of it as a "payment verifier" and start thinking of it as a **point-of-sale terminal** sitting between the customer and the merchant's back office.

```
Customer                 x402-rack                    Vendor (the app)
────────                 ─────────                    ────────────────
                       "400 sats please"
Builds tx            ←
Hands signed BEEF    →   "let me ring that up"
                         ├─ verify the tx pays right
                         ├─ broadcast to ARC      ← cash register ding
                         ├─ record in wallet      ← till drawer closes
                         └─ stamp receipt
                       →  "paid. proceed."
                                                   ← serves the content
```

The customer presents payment. The checkout processes it — settling on-chain and recording the receipt — and only then does the vendor's app deliver the goods. The same role a card reader plays at a physical till: sitting between the customer and the merchant's backend, doing the settlement mechanics so neither party has to.

### Point-of-sale equivalents

| Physical till | x402-rack |
|---|---|
| Card reader | BEEF header parser |
| Bank auth + settlement | `arc.broadcast(subject_tx)` |
| Till drawer | `wallet.internalize_action` |
| Receipt printer | `SettlementResult` with receipt headers |
| "APPROVED / DECLINED" display | HTTP 200 / 402 |
| "TERMINAL UNAVAILABLE" | HTTP 503 |

### Why this framing matters

It explains the design decisions that otherwise look arbitrary:

- **Why does PayGateway broadcast?** The x402 protocol has the server settle the payment. The checkout takes the card and runs the transaction. BRC-121 and BRC-105 have the customer run the transaction first (the spec says so); the checkout just verifies it went through.
- **Why does ARC failure return 503, not 402?** Because an unreachable bank is a shop problem, not a customer problem. The sign reads "TERMINAL DOWN — please try again", not "YOUR CARD IS DECLINED".
- **Why must the `arc_client` be configured?** Because a checkout without a way to check the bank isn't a checkout. Whether we broadcast (PayGateway) or verify (BRC-121/BRC-105), the invariant cannot be enforced without ARC.

### Settlement models

Each gateway follows its spec's settlement model:

```
PayGateway (x402 protocol — server broadcasts):
──────────────────────────────────────────────
Customer: here's my card
Till:     thank you [dip, beep]
Bank:     approved
Till:     proceed

BRC-121 / BRC-105 (client broadcasts per spec):
────────────────────────────────────────────────
Customer: I paid, here's proof
Till:     let me check with the bank
Bank:     status: SEEN_ON_NETWORK
Till:     proceed
```

Same invariant (NO PAY → NO CONTENT). Different mechanics. Same failure modes:

- Under 0.10.2, a customer who hadn't actually paid was rejected *after* the till spent an unpredictable amount of time polling the bank (propagation lag).
- Under 0.11.0, the till just runs the transaction itself — either it succeeds (tx is on-chain) or ARC refuses it (genuine rejection with a clear reason). No polling window, no noSend corner case.

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
- **Broadcasts the payment to ARC before mutating wallet state** (BRC-121 and BRC-105 gateways) **or reads ARC status to confirm prior client broadcast** (ProofGateway) — the NO PAY → NO CONTENT invariant
- Interacts with ARC and/or a treasury service via the BSV wallet

### Gateway Interface

```ruby
#   #challenge_headers(rack_request, route) → Hash
#   #proof_header_names → Array<String>
#   #settle!(header_name, proof_payload, rack_request, route) → result
```

The boundary test: could someone write `X402::EVM::Gateway` implementing this interface without touching `lib/x402/`? If yes, the separation is correct.

### Built-in Gateways

- **`X402::BSV::PayGateway`** — x402 protocol headers, server broadcasts via ARC. See [schemes/bsv-pay.md](schemes/bsv-pay.md).
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
- `Payment-*` — x402 protocol / PayGateway
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
