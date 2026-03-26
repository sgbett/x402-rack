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
- Interacts with ARC and/or a treasury service via the BSV wallet

The gateway interface:

```ruby
#   #challenge_headers(rack_request, route) → Hash
#   #proof_header_names → Array<String>
#   #settle!(header_name, proof_payload, rack_request, route) → result
```

The boundary test: could someone write `X402::EVM::Gateway` implementing this interface without touching `lib/x402/`? If yes, the separation is correct.

### Multi-Protocol Support

Different x402 ecosystems use different HTTP headers. A server can send **multiple challenge headers** simultaneously — the client picks the one it can satisfy. This is payment content negotiation.

| Scheme | Challenge header | Proof header | Receipt header |
|--------|-----------------|--------------|----------------|
| BSV-pay (ours) | `Payment-Required` | `Payment-Signature` | `Payment-Response` |
| BSV-proof (merkleworks) | `X402-Challenge` | `X402-Proof` | — |

Our PayGateway uses the Coinbase v2 headers (`Payment-*`) — the standard x402 ecosystem language. The ProofGateway uses the merkleworks `X402-*` headers. Header namespaces are reserved per ecosystem: `Payment-*` (Coinbase v2 / ours), `X402-*` (merkleworks), `x-bsv-*` (BRC-105 / BSV Association).

## Unified Template Model

### Both gateways produce partial transaction templates

The challenge includes a **partial transaction template** that the client extends by adding funding inputs (and optionally change outputs). This model unifies the two BSV schemes.

**Base behaviour** (`X402::BSV::Gateway`): build a partial tx with the payment output (amount to payee) and an OP_RETURN request binding output.

**ProofGateway override**: prepends the nonce UTXO input at index 0, signed with `SIGHASH_SINGLE | ANYONECANPAY | FORKID (0xC3)`. This locks the payment output (output 0) while allowing the client to append inputs and outputs freely.

**PayGateway**: inherits the base behaviour. Payment output + OP_RETURN binding, no nonce.

The client's job is identical regardless of scheme: add funding inputs, sign, and either broadcast (BSV-proof) or hand to the server (BSV-pay). The delegator fits the same way in both flows.

### Progressive enhancement via `extra.partialTx`

For the PayGateway's `Payment-Required` challenge (Coinbase v2 format), the partial tx template is carried in the `extra` field of the `accepts` entry:

```json
{
  "x402Version": 2,
  "resource": { "url": "/api/expensive" },
  "accepts": [
    {
      "scheme": "exact",
      "network": "bsv:mainnet",
      "amount": "100",
      "asset": "BSV",
      "payTo": "1A1zP1...",
      "maxTimeoutSeconds": 60,
      "extra": {
        "partialTx": "<base64 of partial tx template>"
      }
    }
  ]
}
```

**Basic client** (any x402 v2 client): ignores `extra.partialTx`, constructs a tx from scratch using `payTo` + `amount`.

**Smart client** (BSV-aware): reads `extra.partialTx`, extends the template by adding funding inputs and signing.

The template is an optimisation, not a requirement. `payTo` + `amount` are always sufficient.

### Request binding via OP_RETURN

The partial tx template includes an OP_RETURN output binding the payment to the specific request:

```
Output 0: payment (amount to payee)
Output 1: OP_RETURN <SHA256(method + path + query)>
```

At settlement, the gateway recomputes the hash and verifies it matches. Prevents template redirection between endpoints. Cheap (~30 bytes), on-chain, verifiable. Configurable strict/permissive mode.

### Why 0xC3 for the nonce signature

`SIGHASH_SINGLE | ANYONECANPAY | FORKID`:
- `SIGHASH_SINGLE`: commits only to `output[input_index]` — the nonce at input 0 protects only output 0 (the payment)
- `ANYONECANPAY`: excludes other inputs — funding and fee inputs can be appended freely
- `FORKID`: BSV fork ID flag (required)

Using `0xC1` (`SIGHASH_ALL | ANYONECANPAY`) would commit to ALL outputs, breaking extensibility.

## Two BSV Schemes

### BSV-proof (merkleworks x402 spec)

Client broadcasts, server checks mempool. Proof-of-payment model.

**Headers**: `X402-Challenge` / `X402-Proof`

**Challenge**: merkleworks JSON format including a pre-signed partial tx template (Profile B) with nonce UTXO at input 0 signed with `0xC3`, payment output at output 0, plus request binding metadata, expiry, and `require_mempool_accept: true`.

**Settlement**: gateway verifies tx structure, checks nonce spent at input 0, checks payment output, queries ARC for mempool visibility.

**Why client broadcasts** (per Rui at merkleworks): broadcasting is settlement, not authorisation. Server-side broadcast pushes the server towards a stateful payment processor. Client-side broadcast keeps it stateless.

**Requires**: treasury (nonce provision + template signing) + ARC (mempool queries).

### BSV-pay (our BSV-native scheme)

Server broadcasts via ARC. Uses Coinbase v2 header spec.

**Headers**: `Payment-Required` / `Payment-Signature` / `Payment-Response`

**Challenge**: Coinbase v2 `PaymentRequired` with BSV in `accepts` array, `extra.partialTx` carrying the template (payment output + OP_RETURN binding).

**Settlement**: gateway verifies payment output, verifies OP_RETURN binding, broadcasts to ARC (`X-WaitFor: SEEN_ON_NETWORK`, 5s timeout). ARC 200 → allow. ARC error → relay to client.

**No nonces needed**: ARC is the replay gate. Each tx can only be accepted once.

**Requires**: ARC only. No treasury, no nonce provision.

### Comparison

| | BSV-proof (merkleworks) | BSV-pay (ours) |
|---|---|---|
| Header spec | Merkleworks `X402-*` | Coinbase v2 `Payment-*` |
| Challenge header | `X402-Challenge` | `Payment-Required` |
| Proof header | `X402-Proof` | `Payment-Signature` |
| Receipt header | — | `Payment-Response` |
| Template contains | Nonce input (signed 0xC3) + payment output | Payment output + OP_RETURN binding |
| Who broadcasts | Client | Server (via ARC) |
| Nonce needed | Yes (challenge binding) | No (ARC is replay gate) |
| Request binding | Yes (in challenge metadata) | Yes (OP_RETURN in template) |
| Settlement check | Mempool visibility query | ARC broadcast response |
| Treasury needed | Yes | No |
| Minimum infrastructure | Treasury + ARC | ARC only |
| Ecosystem compatibility | Merkleworks BSV clients | Any x402 v2 client |

## Component Boundaries

| Component | Responsibility | Keys? |
|-----------|---------------|-------|
| **Gatekeeper** (`X402::Middleware`) | HTTP dispatch, route matching | No — MUST NOT hold keys |
| **Gateway** (`X402::BSV::*Gateway`) | Challenge templates, settlement, ARC interaction | Via wallet |
| **BSV Wallet** (`bsv-wallet` gem) | Key management, UTXO tracking, signing | Yes — the security boundary |
| **Treasury** (wallet role) | Mints nonce UTXOs, signs templates | Via wallet's nonce basket |
| **Delegator** (separate service) | Adds fee inputs, signs only fee inputs | Yes — but not our concern |
| **Client** (browser + CWI wallet) | Extends template, signs funding inputs | Yes — client's wallet |

### Server-side wallet

The `bsv-wallet` gem (in the `sgbett/bsv-ruby-sdk` monorepo) provides a BRC-100 interface. Gateways talk to the wallet exclusively through this API — they never touch keys directly. The wallet is the security boundary.

One wallet, multiple roles via baskets:

| Role | Basket | Operations |
|------|--------|------------|
| Treasury | `x402-nonces` | `createAction` (mint nonces, sign templates), `listOutputs` |
| Delegator | `x402-fees` | `signAction` (sign fee inputs), `listOutputs` |
| Payment receipt | `x402-revenue` | `internalizeAction` (accept payments), `listOutputs` |

### Dependency chain

```
x402-rack (no keys, no wallet dependency in middleware)
  └── X402::BSV::*Gateway → bsv-wallet (BRC-100 interface)
                                └── bsv-sdk (primitives)
```

## Ecosystem Context

**Coinbase x402 v2** (broad ecosystem): client signs authorisation, facilitator broadcasts. Headers: `Payment-Required` / `Payment-Signature` / `Payment-Response`.

**Merkleworks x402** (BSV-specific): client broadcasts, server checks mempool. Headers: `X402-Challenge` / `X402-Proof`.

**BRC-105** (BSV Association BRC, future): mutual auth (BRC-103) + derivation-based payments. Headers: `x-bsv-payment-*`.

Our middleware supports all header conventions via the multi-gateway dispatch model. Our PayGateway speaks the standard Coinbase v2 language, making BSV a first-class citizen in the broader x402 ecosystem.

## Client Side

The x402 flow requires a client that intercepts 402 responses, parses challenges, extends transaction templates, handles fee delegation, and presents proof/payment. This is handled by [`bsv-x402`](https://www.npmjs.com/package/bsv-x402) — a separate JavaScript/TypeScript library ([`sgbett/bsv-x402`](https://github.com/sgbett/bsv-x402) on GitHub).

The client wraps `fetch()` and uses BRC-100 (`window.CWI`) to interact with compliant BSV wallets for transaction construction and signing. See that project's documentation for architecture and integration details.

## Current State

The middleware (`X402::Middleware`), configuration, and protocol layer (challenge/proof structures, request binding, base64url encoding) are implemented. BSV-specific logic currently lives in `X402::Verification::SettlementChecks` and needs to migrate into the gateway classes.

Next steps:
1. Extract the gateway interface from the middleware
2. Implement `X402::BSV::Gateway` base class (payment output + OP_RETURN template)
3. Implement `X402::BSV::ProofGateway` (merkleworks compatibility)
4. Implement `X402::BSV::PayGateway` (BSV-native, ARC broadcast, Coinbase v2 headers)
5. Refactor middleware to multi-gateway dispatch

See [`.claude/plans/20260325-bsv-module.md`](.claude/plans/20260325-bsv-module.md) for the detailed implementation plan and [`.claude/plans/20260326-rack-stack-architecture.md`](.claude/plans/20260326-rack-stack-architecture.md) for the full rack stack architecture.
