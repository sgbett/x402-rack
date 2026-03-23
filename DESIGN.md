# x402-rack Design Notes (DRAFT)

## Architecture

The gem has two distinct layers:

### Protocol Layer (`X402::`)

The protocol layer implements the x402 specification: challenge/response flow, proof verification, request binding, and the Rack middleware that ties it together. It is chain-agnostic — it defines **what** must be true for a payment to be valid, not **how** to check it.

Key interfaces the protocol layer expects from an implementation:

- **Nonce provision** — lease a nonce, release it, mark it spent
- **Transaction verification** — does the proof contain a valid spend of the nonce and a payment to the payee?
- **Broadcasting / mempool** — submit a transaction, check whether it's visible on the network

### Implementation Layer (`X402::BSV`)

The BSV implementation provides the chain-specific infrastructure: UTXO pool management, nonce lifecycle, transaction decoding, mempool checking, and broadcasting. This is where state lives.

The boundary test: could someone write `X402::Solana` without touching `lib/x402/`? If yes, the separation is correct.

### Why This Matters

The [reference implementation](https://github.com/merkleworks/x402-bsv) combines protocol logic and BSV infrastructure in a single codebase. This works for a standalone gateway application, but blurs the line between protocol and implementation. Our gem keeps these concerns separate — the protocol layer is stateless, and all state management (UTXO pools, replay caches, mempool gating) belongs to the implementation layer.

The namespace mirrors a hypothetical gem split: `x402` (protocol) and `x402-bsv` (implementation). Even while they ship in the same gem, the boundary is maintained as if they were separate packages.

## Mapping to the x402 Spec Layers

The [x402 specification](https://x402.merkleworks.io/#architecture) defines five layers. Our gem maps to them as follows:

| Spec Layer | Responsibility | Our gem |
|---|---|---|
| Layer 2 — Gatekeeper | Challenge/proof/verification/response gating | `X402::` (protocol layer) |
| Layer 1 — Fee Delegator | UTXO lifecycle, fee sponsorship, tx signing | `X402::BSV` (implementation layer) |
| Layer 0 — Settlement Substrate | BSV network, mempool, single-spend | External (bsv-ruby-sdk + network) |

Layers 3–4 (service products, commercial/legal) are the consuming application's concern.

### Fee Delegation as Scaffolding

The spec describes the Fee Delegator as "the economic kernel" — but it exists primarily because the BSV client ecosystem is immature. If clients could construct, sign, and broadcast transactions natively, the delegator wouldn't be needed. The client would just pay.

This means fee delegation is **compensating for missing client infrastructure**, not an inherent part of the protocol. It should be clearly separated so it can be peeled away as the ecosystem matures without disturbing the protocol core.

In the near term, the economics are: the gateway operator funds a wallet, that wallet mints nonce UTXOs, and requests are effectively free — the payment amount is negligible and there are no real paying clients yet. The "fee" is the cost of running the network, not a revenue stream. This is the bootstrap phase.

### State: Inventory, Not Sessions

The protocol is stateless in the HTTP sense — no cookies, no sessions, no server-side request tracking. The pressure to add state comes from nonce management: the gateway must have UTXOs to issue as nonces.

This is **inventory**, not session state. The nonce pool is analogous to a vending machine's coin hopper — it needs restocking, but each transaction is independent. Pool management logic must not leak into the verification pipeline or the middleware.

## Nonce Provider: Staged Implementation

The nonce provider interface (`nonce_provider` callable) stays the same across all stages. The middleware calls it and gets a nonce back. The consumer upgrades by swapping the provider, not by rewiring the protocol.

### Stage 1: Echo Mode (Default)

The nonce provider calls out to a remote wallet/delegator service that hands back a fresh nonce UTXO. The gem itself holds no keys, no pool, no state. Pure pass-through.

This is the starting point. It keeps the gem genuinely stateless and is sufficient for the bootstrap phase where a single funded wallet can service the entire nascent network.

### Stage 2: Local Pool (If Needed)

Pre-fetch nonces from the remote wallet in batches, hold them in memory, lease them out locally. Still no keys in the gem — just a cache of pre-minted UTXOs.

Solves: latency (eliminates per-challenge round-trip), availability (buffer against remote wallet downtime), burst capacity.

Only needed when request volume makes the per-challenge remote call a bottleneck.

### Stage 3: Full Local Mode (If Needed)

The gem holds keys and mints its own nonces. This is what the reference implementation does. It's the end of the road, not the starting point.

Only needed for fully autonomous gateway deployments at scale.

### A Note on BSV Network Capacity

The staged plan above might suggest the BSV network is the scaling constraint. It isn't. BSV already scales far beyond what most people realise — generating a nonce is just creating a transaction, ARC handles mempool acceptance reliably, and fees are negligible (1–50 sats). The average website will never need a local pool.

The real bottleneck is ecosystem maturity: client tooling, wallet infrastructure, developer familiarity. The BSV network itself is unlikely to be the limiting factor at any realistic adoption level in the foreseeable future.

This means Stage 1 (echo mode) isn't a compromise — it's likely the permanent answer for most deployments. Stages 2 and 3 exist as options, not as an expected migration path.

### When to Advance

Each stage only happens when the previous one hits a real limitation. The interface contract doesn't change — only the implementation behind it.

## Client Side

The x402 flow requires a client that intercepts 402 responses, parses challenges, constructs payment transactions, broadcasts them, and retries with proof. This is handled by [`bsv-x402`](https://www.npmjs.com/package/bsv-x402) — a separate JavaScript/TypeScript library ([`sgbett/bsv-x402`](https://github.com/sgbett/bsv-x402) on GitHub).

The client wraps `fetch()` and uses BRC-100 (`window.CWI`) to interact with compliant BSV wallets for transaction construction and signing. See that project's documentation for architecture and integration details.

## Current State

The protocol layer (`X402::Protocol`, `X402::Verification`, `X402::Middleware`, `X402::Configuration`) is implemented. BSV-specific logic currently lives in `X402::Verification::SettlementChecks` and needs to migrate behind the implementation boundary as `X402::BSV` takes shape.

The `nonce_provider` callable in configuration is the first backend integration point. It will evolve into a richer interface as the BSV implementation grows to cover the full nonce lifecycle (lease, release, mark spent) and related concerns (pool management, broadcasting, mempool checking).
