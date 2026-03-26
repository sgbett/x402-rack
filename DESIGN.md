# x402-rack Design Notes (DRAFT)

## Architecture

### Middleware as Dispatcher (`X402::Middleware`)

The Rack middleware is a **pure dispatcher** — the gatekeeper. It has no blockchain knowledge. It:

1. Matches incoming requests against protected routes
2. Polls each configured gateway for challenge headers, returns all of them in the 402 response
3. Checks which proof/payment header the client sent, dispatches to the matching gateway
4. The gateway returns allow/deny — the middleware serves or rejects accordingly

The middleware never decodes transactions, checks mempool, broadcasts, or interacts with any blockchain network. It manages HTTP headers, route matching, and dispatch.

**The gatekeeper MUST NOT sign transactions or hold private keys.**

### Gateways (`X402::BSV::ProofGateway`, `X402::BSV::PayGateway`)

Gateways are pluggable backends that handle chain-specific settlement. They **can** hold keys and sign transactions — they are separate components from the gatekeeper. Each gateway:

- Builds challenge data (including partial transaction templates)
- Verifies and settles proofs
- Interacts with ARC and/or a treasury service

The gateway interface:

```ruby
#   #challenge_headers(rack_request, route) → Hash
#   #proof_header_names → Array<String>
#   #settle!(header_name, proof_payload, rack_request, route) → result
```

The boundary test: could someone write `X402::EVM::Gateway` implementing this interface without touching `lib/x402/`? If yes, the separation is correct.

### Multi-Protocol Support

Different x402 ecosystems use different HTTP headers. A server can send **multiple challenge headers** simultaneously — the client picks the one it can satisfy. This is payment content negotiation.

| Scheme | Challenge header | Proof header |
|--------|-----------------|--------------|
| BSV-proof (merkleworks) | `X402-Challenge` | `X402-Proof` |
| BSV-pay (ours) | `X402-Challenge` | `X402-Pay` |
| Coinbase v2 (future) | `Payment-Required` | `Payment-Signature` |

## Unified Template Model

### Both gateways produce partial transaction templates

The challenge includes a **partial transaction template** that the client extends by adding funding inputs (and optionally change outputs). This model unifies the two BSV schemes.

**Base behaviour** (all BSV gateways): build a partial tx with the payment output (amount to payee).

**ProofGateway**: prepends the nonce UTXO input at index 0, signed with `SIGHASH_SINGLE | ANYONECANPAY | FORKID (0xC3)`. This locks the payment output (output 0) while allowing the client to append inputs and outputs freely. Then adds the payment output.

**PayGateway**: just the base behaviour. Payment output, no nonce.

The client's job is identical regardless of scheme: add funding inputs, sign, and either broadcast (BSV-proof) or hand to the server (BSV-pay). The delegator fits the same way in both flows.

### Why 0xC3 for the nonce signature

`SIGHASH_SINGLE | ANYONECANPAY | FORKID`:
- `SIGHASH_SINGLE`: commits only to `output[input_index]` — the nonce at input 0 protects only output 0 (the payment)
- `ANYONECANPAY`: excludes other inputs — funding and fee inputs can be appended freely
- `FORKID`: BSV fork ID flag (required)

Using `0xC1` (`SIGHASH_ALL | ANYONECANPAY`) would commit to ALL outputs, breaking extensibility.

## Two BSV Schemes

### BSV-proof (merkleworks x402 spec)

Client broadcasts, server checks mempool. Proof-of-payment model.

**Challenge**: merkleworks JSON format including a pre-signed partial tx template (Profile B) with nonce UTXO at input 0 signed with `0xC3`, payment output at output 0, plus request binding metadata (method, path, query, headers hash, body hash), expiry, and `require_mempool_accept: true`.

**Client flow**: extend template with funding inputs → delegator adds fees → broadcast → retry with proof (txid + rawtx)

**Settlement**: gateway verifies tx structure, checks nonce spent at input 0, checks payment output, queries ARC for mempool visibility.

**Why client broadcasts** (per Rui at merkleworks): broadcasting is settlement, not authorisation. If the server broadcasts, it takes on transaction submission responsibility, retry/reconciliation logic, and mempool interaction state — pushing it towards a stateful payment processor. Client-side broadcast keeps the server stateless.

**Requires**: treasury (nonce provision + template signing) + ARC (mempool queries).

### BSV-pay (our BSV-native scheme)

Server broadcasts via ARC. Simpler flow, no nonces needed.

**Challenge**: partial tx template with payment output only (no nonce).

**Client flow**: extend template with funding inputs → delegator adds fees → hand completed tx to server

**Settlement**: gateway verifies payment output, broadcasts to ARC. ARC 200 → allow. ARC error → deny (relay error to client).

**No nonces needed**: ARC is the replay gate. Each tx can only be accepted once. The tx itself is the replay protection.

**No request binding needed**: ARC acceptance proves freshness.

**Requires**: ARC only. No treasury, no nonce provision.

### Comparison

| | BSV-proof (merkleworks) | BSV-pay (ours) |
|---|---|---|
| Template contains | Nonce input (signed 0xC3) + payment output | Payment output only |
| Who broadcasts | Client | Server (via ARC) |
| Nonce needed | Yes (challenge binding) | No (ARC is replay gate) |
| Request binding | Yes (in challenge metadata) | No (ARC acceptance = freshness) |
| Settlement check | Mempool visibility query | ARC broadcast response |
| Treasury needed | Yes | No |
| Minimum infrastructure | Treasury + ARC | ARC only |

## Component Boundaries

| Component | Responsibility | Keys? |
|-----------|---------------|-------|
| **Gatekeeper** (`X402::Middleware`) | HTTP dispatch, route matching | No — MUST NOT hold keys |
| **Gateway** (`X402::BSV::*Gateway`) | Challenge templates, settlement, ARC interaction | Yes — can hold nonce key |
| **Treasury** (external or local) | Mints nonce UTXOs, holds nonce key | Yes |
| **Delegator** (separate service) | Adds fee inputs, signs only fee inputs | Yes — but not our concern |
| **Client** (browser + CWI wallet) | Extends template, signs funding inputs | Yes — client's wallet |

## Ecosystem Context

Two x402 ecosystems exist:

**Coinbase x402 v2** (broad ecosystem): client signs authorisation, facilitator broadcasts. Verify → serve → settle (async). No server-provided nonces. `accepts` array for multi-chain negotiation. Headers: `Payment-Required` / `Payment-Signature` / `Payment-Response`.

**Merkleworks x402** (BSV-specific): client broadcasts, server checks mempool. Server-provided nonce UTXO for challenge binding. Strong request binding. Headers: `X402-Challenge` / `X402-Proof`.

Our middleware supports both header conventions via the multi-gateway dispatch model. Coinbase will gatekeep BSV from their ecosystem — our conformance is about making it easy for others to integrate BSV as a supported network.

## Client Side

The x402 flow requires a client that intercepts 402 responses, parses challenges, extends transaction templates, handles fee delegation, and presents proof/payment. This is handled by [`bsv-x402`](https://www.npmjs.com/package/bsv-x402) — a separate JavaScript/TypeScript library ([`sgbett/bsv-x402`](https://github.com/sgbett/bsv-x402) on GitHub).

The client wraps `fetch()` and uses BRC-100 (`window.CWI`) to interact with compliant BSV wallets for transaction construction and signing. See that project's documentation for architecture and integration details.

## Current State

The middleware (`X402::Middleware`), configuration, and protocol layer (challenge/proof structures, request binding, base64url encoding) are implemented. BSV-specific logic currently lives in `X402::Verification::SettlementChecks` and needs to migrate into `X402::BSV::ProofGateway`.

Next steps:
1. Extract the gateway interface from the middleware
2. Implement `X402::BSV::Gateway` base class (payment output template)
3. Implement `X402::BSV::ProofGateway` (merkleworks compatibility)
4. Implement `X402::BSV::PayGateway` (BSV-native, ARC broadcast)
5. Refactor middleware to multi-gateway dispatch

See [`.claude/plans/20260325-bsv-module.md`](.claude/plans/20260325-bsv-module.md) for the detailed implementation plan.
