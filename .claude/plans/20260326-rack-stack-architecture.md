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
┌───┴────┐  ┌───┴───┐  ┌────┴────┐
│Treasury│  │  ARC  │  │ BRC-100 │  External services
│+ ARC   │  │       │  │ Wallet  │
└────────┘  └───────┘  └─────────┘
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

### BSV ProofGateway (merkleworks x402)
- **Challenge**: pre-signed partial tx template (nonce at input 0 with 0xC3, payment output at output 0) + merkleworks challenge JSON (binding, expiry)
- **Settlement**: verify tx structure, check mempool via ARC
- **Headers**: `X402-Challenge` / `X402-Proof`
- **Needs**: treasury (nonce key) + ARC
- **Identity**: not required

### BSV PayGateway (our BSV-native scheme)
- **Challenge**: partial tx template (payment output only)
- **Settlement**: verify tx structure, broadcast via ARC
- **Headers**: `X402-Challenge` / `X402-Pay`
- **Needs**: ARC only
- **Identity**: not required

### BRC-105 Gateway (future)
- **Challenge**: derivation prefix + satoshis required (multiple `x-bsv-payment-*` headers)
- **Settlement**: verify derivation, validate tx via BRC-100 wallet (`internalizeAction`)
- **Headers**: `x-bsv-payment-*` / `x-bsv-payment`
- **Needs**: BRC-100 wallet
- **Identity**: REQUIRED (reads `env['brc103.identity_key']` for derivation)

### Coinbase v2 Gateway (future)
- **Challenge**: `PaymentRequired` JSON with `accepts` array
- **Settlement**: verify signature, settle via facilitator (or locally)
- **Headers**: `Payment-Required` / `Payment-Signature` / `Payment-Response`
- **Needs**: facilitator service (or local chain access)
- **Identity**: not required (Coinbase uses wallet signatures, not session auth)

## External Services

### ARC (BSV transaction processor)
- Broadcasts transactions and returns acceptance/rejection
- Queries mempool visibility for already-broadcast txs
- Used by: ProofGateway (mempool queries), PayGateway (broadcast)
- API: https://docs.bsvblockchain.org/important-concepts/details/spv/broadcasting

### Treasury
- Holds nonce key, mints 1-sat nonce UTXOs, signs partial tx templates with 0xC3
- Used by: ProofGateway only
- Could be: external service (via `wallet_url`) or local key in the gateway

### Delegator
- Adds fee inputs to client-constructed partial txs, signs only its fee inputs
- Used by: clients (not servers). The server stack never talks to the delegator.
- Separate service entirely — could be operated by the gateway operator or a third party

### BRC-100 Wallet
- Standard BSV wallet API (createAction, internalizeAction, listOutputs, etc.)
- Used by: BRC-105 Gateway (server-side tx validation), clients (tx construction)
- Implementations: BSV Browser, other CWI-compliant wallets

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
    ├── ProofGateway.challenge_headers(request, route)
    │   Returns X402-Challenge header (ignores identity — doesn't need it)
    │
    ├── PayGateway.challenge_headers(request, route)
    │   Returns X402-Challenge header (ignores identity)
    │
    ├── BRC105Gateway.challenge_headers(request, route)
    │   Reads env['brc103.identity_key']
    │   If present → returns x-bsv-payment-* headers (with derivation prefix)
    │   If absent → returns {} (declines — can't work without identity)
    │
    ▼
402 Response with all non-empty challenge headers
```

A client with a BRC-100 wallet and BRC-103 auth gets all three challenge options. A client with just a BSV wallet gets ProofGateway and PayGateway challenges. The client picks whichever it supports.

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
    ├── Has X402-Proof? → dispatch to ProofGateway.settle!()
    │   Gateway verifies tx, checks mempool via ARC
    │   Returns: allow + settlement result
    │
    ├── Has X402-Pay? → dispatch to PayGateway.settle!()
    │   Gateway verifies tx, broadcasts via ARC
    │   Returns: allow + settlement result (incl. ARC response)
    │
    ├── Has x-bsv-payment? → dispatch to BRC105Gateway.settle!()
    │   Gateway verifies derivation + tx via BRC-100 wallet
    │   Returns: allow + settlement result
    │
    ▼
Allow → forward to application
Deny → return error to client
```

## What Each Component Knows

| Component | Knows about HTTP | Knows about BSV | Knows about identity | Holds keys |
|-----------|:---:|:---:|:---:|:---:|
| BRC-104 Auth Middleware | Yes | Signatures only | Yes — its job | Session keys |
| X402 Middleware | Yes | No | Passes through | No |
| ProofGateway | Headers only | Yes | No | Nonce key |
| PayGateway | Headers only | Yes | No | No |
| BRC-105 Gateway | Headers only | Yes | Yes (reads from env) | Derivation key |
| Treasury | No | Yes | No | Nonce key |
| ARC | No | Yes | No | No |
| Delegator | No | Yes | No | Fee keys |
| Client | Yes | Yes | Optionally | Wallet keys |

## Gem Boundaries

| Gem | Contains |
|-----|---------|
| `x402-rack` | X402::Middleware (gatekeeper), gateway interface, X402::BSV::ProofGateway, X402::BSV::PayGateway |
| `brc104-rack` (future, separate) | BRC-104 auth middleware |
| `brc105-gateway` (future, separate or in x402-rack) | X402::BSV::BRC105Gateway |
| `bsv-x402` (npm, separate repo) | Client-side fetch wrapper, CWI integration |

## Design Principles

1. **Each layer handles one concern.** Auth is auth. Payment is payment. Settlement is settlement. They compose, they don't merge.

2. **The gatekeeper is dumb.** It dispatches. It doesn't understand what it's dispatching. Blockchain knowledge lives in gateways.

3. **Gateways are pluggable.** New settlement protocols = new gateway classes. No middleware changes.

4. **Identity is optional and upstream.** Payment gating works without identity. Identity enriches the options (BRC-105) but doesn't gate them.

5. **External services are the gateway's concern.** The middleware never talks to ARC, wallets, or treasuries. Gateways own those relationships.

6. **The client chooses.** Multiple challenge headers, client picks. Payment content negotiation.

7. **State lives on-chain.** No server-side nonce pools, no session tracking, no balance ledgers. The blockchain is the state (with one exception: BRC-105's derivation prefix tracking, which is the BRC-100 wallet's concern).
