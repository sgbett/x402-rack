# Architecture

## Core invariant

> **x402-rack serves content if and only if the vendor has broadcast the payment transaction to the BSV network.**

This is the one job. `BRC121Gateway` and `BRC105Gateway` enforce it by broadcasting the client's signed BEEF to ARC themselves, after the payment output has been verified but **before** any wallet or replay state is mutated. ARC's idempotency means duplicate broadcasts (when the client has already broadcast) are safe — they return 2xx without duplicating work. `ProofGateway` keeps its original semantics (client broadcasts first, server reads ARC status via `arc_client.status(txid)`) because the scheme is explicitly proof-of-prior-payment.

Failures bifurcate cleanly in the HTTP response:

- **402** — ARC rejected the broadcast (malformed tx, insufficient funds, double-spend; client fault)
- **503** — ARC unreachable / 5xx / timeout (infrastructure fault)

See [schemes/brc-121.md](schemes/brc-121.md#vendor-broadcast) and [schemes/brc-105.md](schemes/brc-105.md#vendor-broadcast) for the per-gateway specifics.

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

- **Why does the vendor broadcast?** Because the checkout takes the card and runs the transaction. It doesn't ask the customer to run a parallel transaction with the bank and present proof — it *is* the settlement point.
- **Why is ARC idempotency the load-bearing property?** Because the card reader always dials the bank, even if you've already paid somewhere else with the same card today. The bank handles deduplication; the reader doesn't need to second-guess.
- **Why no `verify_on_chain` kill-switch?** Because a till that lets you turn off "actually process the payment" isn't a till any more. The checkout either settles or refuses — there's no halfway.
- **Why does ARC failure return 503, not 402?** Because an unreachable bank is a shop problem, not a customer problem. The sign reads "TERMINAL DOWN — please try again", not "YOUR CARD IS DECLINED".
- **Why must the `arc_client` be configured?** Because a checkout without a card reader isn't a checkout. The invariant cannot be enforced without the network-write primitive.

### The pivot from 0.10.2 to 0.11.0

This model also explains why 0.10.2 felt wrong. The status-check approach (0.10.2) was like a till that asks "did you pay the bank yet?" — making the customer do the transaction and then showing proof. The vendor-broadcast approach (0.11.0) is like a till that *takes* the card and *runs* the transaction. Cleaner, and matches what retailers actually do.

```
0.10.2 (status-check — wrong):          0.11.0 (vendor-broadcast — right):
─────────────────────────────          ──────────────────────────────────
Customer: I paid, here's proof         Customer: here's my card
Till:     let me check with the bank   Till:     thank you [dip, beep]
Bank:     status: SEEN_ON_NETWORK      Bank:     approved
Till:     proceed                      Till:     proceed
```

Same outcome when everything works. Different failure modes:

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
