# Architecture: The Rack Stack for BSV HTTP Services

## Overview

HTTP services monetised with BSV require several orthogonal concerns to be handled: identity, payment, fee sponsorship, and settlement. These concerns compose naturally as a Rack middleware stack, where each layer handles one responsibility and passes context downstream.

This plan defines the component parts and their boundaries. It is deliberately not concerned with implementation specifics — it maps the jigsaw pieces and how they fit together.

## The Stack

```
┌─────────────────────────────────────────────┐
│  TLS (transport security)                   │  Not our concern — handled by web server
├─────────────────────────────────────────────┤
│  BRC-104 Auth Middleware (optional)         │  Identity — who is this?
├─────────────────────────────────────────────┤
│  X402 Middleware (gatekeeper)               │  Payment gating — have they paid?
├─────────────────────────────────────────────┤
│  Application                                │  Business logic — serve the resource
└─────────────────────────────────────────────┘

         ┌──────────────┐
         │   Gateways   │  Settlement — how do they pay?
         └──────┬───────┘
                │
    ┌───────────┼───────────┐
    │           │           │
┌───┴────┐  ┌───┴────┐ ┌────┴────┐
│ BSV    │  │  BSV   │ │ BRC-105 │  ... extensible
│ Proof  │  │  Pay   │ │ Gateway │
└───┬────┘  └───┬────┘ └────┬────┘
    │           │           │
    └───────────┼───────────┘
                │
         ┌──────┴───────┐
         │  BSV Wallet  │  Server-side wallet (BRC-100 interface)
         │  (bsv-wallet │  Manages keys, UTXOs, signing
         │   gem)       │  via baskets: nonces, fees, revenue
         └──────┬───────┘
                │
         ┌──────┴───────┐
         │   bsv-sdk    │  Primitives — keys, txs, scripts, ARC
         └──────────────┘
```

## Layer 1: Identity (BRC-103/104)

**What**: Mutual authentication between client and server. Establishes who is making the request.

**Rack middleware**: Verifies `x-bsv-auth-*` headers, validates BRC-103 signatures over the request (method, path, query, whitelisted headers, body). Places the authenticated identity into the Rack env.

**Provides to downstream**: `env['brc103.identity_key']` (33-byte compressed public key), session nonces, certificate data.

**Optional**: Not all payment flows require identity. Anonymous payments (merkleworks x402, BSV-pay) work without this layer. BRC-105 payments require it.

**Not our gem**: This would be a separate gem (`brc104-rack` or similar). Our x402 middleware doesn't depend on it — it just benefits from it when present.

## Layer 2: Payment Gating (X402 Middleware)

**What**: The gatekeeper. Decides whether a request should be served based on payment status.

**Responsibilities**:
- Route matching — is this request to a protected endpoint?
- Challenge issuance — poll gateways, return 402 with challenge headers
- Proof dispatch — detect which proof header arrived, dispatch to the matching gateway
- Access control — gateway says allow/deny, middleware serves or rejects

**Does NOT do**:
- Sign transactions
- Hold private keys
- Decode blockchain data
- Talk to ARC or any network service
- Know what chain or protocol is being used

**Rack env it reads**: route configuration, gateway list. Optionally `env['brc103.identity_key']` (passes through to gateways that need it).

**Rack env it sets**: settlement result (for downstream logging/receipt headers).

**This is our gem**: `x402-rack`.

## Layer 3: Settlement (Gateways)

**What**: The bridge between HTTP and blockchain. Each gateway knows one settlement protocol.

**Responsibilities**:
- Build challenge data (headers + partial tx templates)
- Verify and settle proofs/payments
- Interact with external services (ARC, treasury, wallets)
- Can hold keys and sign transactions

**Gateway types identified so far**:

### BSV PayGateway (our BSV-native scheme — Coinbase v2 headers)
- **Challenge**: `PaymentRequired` JSON with BSV in `accepts` array + partial tx template (payment output only)
- **Settlement**: verify tx structure, broadcast via ARC, return `Payment-Response`
- **Headers**: `Payment-Required` / `Payment-Signature` / `Payment-Response`
- **Needs**: ARC only
- **Identity**: not required
- **Ecosystem**: standard x402 v2 — interoperable with any Coinbase-compatible client

### BSV ProofGateway (merkleworks x402)
- **Challenge**: pre-signed partial tx template (nonce at input 0 with 0xC3, payment output at output 0) + merkleworks challenge JSON (binding, expiry)
- **Settlement**: verify tx structure, check mempool via ARC
- **Headers**: `X402-Challenge` / `X402-Proof`
- **Needs**: treasury (nonce key) + ARC
- **Identity**: not required
- **Ecosystem**: merkleworks BSV-specific

### BRC-105 Gateway (future)
- **Challenge**: derivation prefix + satoshis required (multiple `x-bsv-payment-*` headers)
- **Settlement**: verify derivation, validate tx via BRC-100 wallet (`internalizeAction`)
- **Headers**: `x-bsv-payment-*` / `x-bsv-payment`
- **Needs**: BRC-100 wallet
- **Identity**: REQUIRED (reads `env['brc103.identity_key']` for derivation)
- **Ecosystem**: BSV Association BRC standard

## Server-Side Wallet (`bsv-wallet` gem)

### One wallet, multiple roles

The treasury, delegator, and payment receipt functions are not separate services — they are **roles** a single wallet plays, distinguished by which baskets and keys they use.

| Role | Basket | Key | Operations |
|------|--------|-----|------------|
| Treasury | `x402-nonces` | Nonce key | `createAction` (mint nonces, sign templates), `listOutputs` |
| Delegator | `x402-fees` | Fee key | `signAction` (sign fee inputs), `listOutputs` |
| Payment receipt | `x402-revenue` | Payee key | `internalizeAction` (accept payments), `listOutputs` |

### BRC-100 as the API boundary

The wallet exposes a BRC-100 interface (or the subset we need). Gateways talk to the wallet exclusively through these methods. They never touch keys directly. The wallet is the security boundary.

**BRC-100 methods we need** (subset of the full 28+ method spec):
- `createAction` — construct and sign transactions (nonce minting, template signing)
- `signAction` — sign previously created transactions (fee input signing)
- `internalizeAction` — accept incoming transactions (payment receipt)
- `listOutputs` — query UTXOs by basket (find nonces, fee UTXOs, revenue)
- `getPublicKey` — derive keys (BRC-29 derivations for BRC-105, nonce keys)

### Where it lives

The `bsv-ruby-sdk` repo (`sgbett/bsv-ruby-sdk`) already has:
- A monorepo pattern with multiple gemspecs (`bsv-sdk`, `bsv-attest`)
- A basic wallet at `lib/bsv/wallet/wallet.rb` (single-key, UTXO funding + signing)
- Full key management including BIP-32 HD derivation
- Transaction construction with BIP-143 sighash (FORKID)
- ARC provider
- BEEF serialisation

The `bsv-wallet` gem adds a third gemspec to this repo:
- BRC-100 interface layer over the existing primitives
- Basket-based UTXO tracking (nonces, fees, revenue)
- Multi-key support
- Builds on the existing `BSV::Wallet::Wallet` as the internal engine

### Deployment options

The BRC-100 interface works regardless of deployment:

1. **In-process** — `require 'bsv-wallet'`, gateway calls wallet methods directly. Simplest. Keys in the same process.
2. **Local service** — wallet runs as a separate process, gateways call via HTTP. Process isolation.
3. **Remote service** — wallet on a different machine. Network boundary. Strongest isolation.

Same interface, different transports. Start with in-process, separate later if needed.

### Separation from middleware

The wallet gem has a strict public API (BRC-100 methods only). The `x402-rack` gem depends on `bsv-wallet` but only through this interface. The middleware itself (`X402::Middleware`) never talks to the wallet — only gateways do.

```
x402-rack (no keys, no wallet dependency)
  └── X402::Middleware
  └── X402::BSV::ProofGateway ──→ BSV::Wallet (BRC-100 API)
  └── X402::BSV::PayGateway ────→ BSV::Wallet (BRC-100 API, for ARC only)
```

## External Services

### ARC (BSV transaction processor)
- Broadcasts transactions and returns acceptance/rejection
- Queries mempool visibility for already-broadcast txs
- Used by: wallet (via `bsv-sdk` ARC provider)
- API: https://docs.bsvblockchain.org/important-concepts/details/spv/broadcasting

### Delegator (client-side concern)
- Adds fee inputs to client-constructed partial txs, signs only its fee inputs
- Used by: clients (not servers). The server stack never talks to the delegator.
- Separate service entirely — could be operated by the gateway operator or a third party
- Could itself be powered by a `bsv-wallet` instance in the "fees" role

## How Identity Flows Through the Stack

```
Request arrives
    │
    ▼
BRC-104 Auth Middleware
    │  Verifies x-bsv-auth-* headers
    │  Sets env['brc103.identity_key'] = "02abc..."
    │  Sets env['brc103.certificates'] = [...]
    │
    ▼
X402 Middleware
    │  Reads route config → protected, costs 100 sats
    │  No proof header → issue challenges
    │  Passes env (including identity) to each gateway
    │
    ├── PayGateway.challenge_headers(request, route)
    │   Returns Payment-Required header (v2 JSON with BSV in accepts)
    │
    ├── ProofGateway.challenge_headers(request, route)
    │   Returns X402-Challenge header (merkleworks format)
    │
    ├── BRC105Gateway.challenge_headers(request, route)
    │   Reads env['brc103.identity_key']
    │   If present → returns x-bsv-payment-* headers (with derivation prefix)
    │   If absent → returns {} (declines — can't work without identity)
    │
    ▼
402 Response with all non-empty challenge headers
```

A client with a BRC-100 wallet and BRC-103 auth gets all three challenge options. A standard x402 v2 client gets the `Payment-Required` header and can pay with BSV. A merkleworks-specific client uses `X402-Challenge`. The client picks whichever it supports.

## How Payment Flows Through the Stack

```
Request arrives with proof header
    │
    ▼
BRC-104 Auth Middleware (if present)
    │  Authenticates, sets env['brc103.identity_key']
    │
    ▼
X402 Middleware
    │  Reads route config → protected, costs 100 sats
    │  Detects proof header
    │
    ├── Has Payment-Signature? → dispatch to PayGateway.settle!()
    │   Gateway verifies tx, broadcasts via ARC
    │   Returns: allow + settlement result + Payment-Response header
    │
    ├── Has X402-Proof? → dispatch to ProofGateway.settle!()
    │   Gateway verifies tx, checks mempool via ARC
    │   Returns: allow + settlement result
    │
    ├── Has x-bsv-payment? → dispatch to BRC105Gateway.settle!()
    │   Gateway verifies derivation + tx via BRC-100 wallet
    │   Returns: allow + settlement result
    │
    ▼
Allow → forward to application (with receipt headers if provided)
Deny → return error to client
```

## What Each Component Knows

| Component | Knows about HTTP | Knows about BSV | Knows about identity | Holds keys |
|-----------|:---:|:---:|:---:|:---:|
| BRC-104 Auth Middleware | Yes | Signatures only | Yes — its job | Session keys |
| X402 Middleware | Yes | No | Passes through | No |
| ProofGateway | Headers only | Via wallet | No | No — wallet holds them |
| PayGateway | Headers only | Via wallet | No | No — wallet holds them |
| BRC-105 Gateway | Headers only | Via wallet | Yes (reads from env) | No — wallet holds them |
| BSV Wallet | No | Yes — its job | No | Yes — the security boundary |
| ARC | No | Yes | No | No |
| Delegator | No | Via wallet | No | No — wallet holds them |
| Client | Yes | Yes | Optionally | Wallet keys |

## Gem Boundaries

| Gem | Repo | Contains |
|-----|------|---------|
| `bsv-sdk` | `sgbett/bsv-ruby-sdk` | Primitives — keys, transactions, scripts, ARC provider |
| `bsv-wallet` | `sgbett/bsv-ruby-sdk` | BRC-100 wallet interface, basket UTXO tracking, multi-key management. Depends on `bsv-sdk`. |
| `x402-rack` | `sgbett/x402-rack` | X402::Middleware (gatekeeper), gateway interface, X402::BSV::ProofGateway, X402::BSV::PayGateway. Gateways depend on `bsv-wallet`. |
| `brc104-rack` (future) | Separate | BRC-104 auth middleware |
| `bsv-x402` (npm) | `sgbett/bsv-x402` | Client-side fetch wrapper, CWI integration |

### Dependency chain

```
x402-rack
  └── bsv-wallet (BRC-100 interface only)
        └── bsv-sdk (primitives)
```

The middleware itself has no dependency on `bsv-wallet` or `bsv-sdk`. Only the gateway classes do. A pure middleware deployment (dispatching to remote gateways) wouldn't need the BSV gems at all.

## Design Principles

1. **Each layer handles one concern.** Auth is auth. Payment is payment. Settlement is settlement. They compose, they don't merge.

2. **The gatekeeper is dumb.** It dispatches. It doesn't understand what it's dispatching. Blockchain knowledge lives in gateways.

3. **Gateways are pluggable.** New settlement protocols = new gateway classes. No middleware changes.

4. **Identity is optional and upstream.** Payment gating works without identity. Identity enriches the options (BRC-105) but doesn't gate them.

5. **External services are the gateway's concern.** The middleware never talks to ARC, wallets, or treasuries. Gateways own those relationships.

6. **The client chooses.** Multiple challenge headers, client picks. Payment content negotiation.

7. **State lives on-chain.** No server-side nonce pools, no session tracking, no balance ledgers. The blockchain is the state (with one exception: BRC-105's derivation prefix tracking, which is the BRC-100 wallet's concern).
