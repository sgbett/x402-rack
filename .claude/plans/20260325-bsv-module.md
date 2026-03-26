# Plan: X402::BSV Module — Responsibilities and Interface

## Context

The codebase has BSV-specific logic in `X402::Verification::SettlementChecks` that needs to move behind an `X402::BSV` boundary. Through analysis of the merkleworks reference implementation (including Profile B settlement flow), the Coinbase x402 ecosystem, and direct discussion with Rui at merkleworks, the architecture has clarified into clean component boundaries.

### Ecosystem landscape

Two x402 ecosystems exist with different conventions:

**Coinbase x402 v2** (broad ecosystem):
- Headers: `Payment-Required` / `Payment-Signature` / `Payment-Response`
- Client signs authorisation, facilitator broadcasts (verify → serve → settle)
- No server-provided nonces — replay protection is chain-native (EIP-712, etc.)
- No request binding beyond resource URL
- `accepts` array in challenge for multi-chain/multi-scheme negotiation

**Merkleworks x402** (BSV-specific):
- Headers: `X402-Challenge` / `X402-Proof`
- Client broadcasts, server checks mempool (proof-of-payment model)
- Server-provided 1-sat nonce UTXO for challenge binding + replay protection
- Strong request binding (method, path, query, headers hash, body hash)
- Single-chain, single-scheme

**Our position**: Our PayGateway implements the Coinbase v2 header spec (`Payment-Required` / `Payment-Signature` / `Payment-Response`) with BSV as the settlement network. This makes BSV a first-class citizen in the broader x402 ecosystem — any Coinbase-compatible server or client can interoperate with us. We also support merkleworks via a separate ProofGateway that uses the `X402-*` headers. The `X402-*` headers are merkleworks' territory; we speak the standard x402 v2 language for our own scheme.

## Component Boundaries

### Gatekeeper (`X402::Middleware`)

The Rack middleware. A pure dispatcher with no blockchain knowledge. It:

1. **On request**: polls each configured gateway for challenge headers, returns all of them in the 402 response
2. **On proof**: checks which proof/payment header the client sent, dispatches to the matching gateway
3. **On result**: the gateway returns allow/deny — the middleware serves or rejects accordingly

The gatekeeper **MUST NOT sign transactions or hold private keys** (Invariant A-2 from the merkleworks spec). It manages HTTP headers, route matching, and dispatch. Everything else is the gateway's job.

### Gateway (`X402::BSV::ProofGateway`, `X402::BSV::PayGateway`)

The bridge between the gatekeeper and the BSV network. Gateways **can** hold keys and sign transactions — they are separate components from the gatekeeper. Each gateway:

- Builds challenge data (including partial transaction templates)
- Verifies and settles proofs
- Interacts with ARC and/or a treasury service

### Treasury (external service or local key)

Holds the nonce key, mints nonce UTXOs. The ProofGateway either talks to an external treasury service (`wallet_url`) or holds a key directly (`nonce_key`). The PayGateway doesn't need a treasury.

### Delegator (separate service, not our concern)

Adds fee inputs to client-constructed partial txs, signs only its fee inputs. Lives between the client and the network. The gatekeeper and gateways never talk to it.

## Architecture: Unified Template Model

### The key insight: both gateways produce partial transaction templates

The challenge is not just metadata — it includes a **partial transaction template** that the client extends by adding funding inputs (and optionally change outputs).

**Base behaviour** (all gateways): build a partial tx with the payment output (amount to payee). This is the invoice.

**ProofGateway override**: prepend the nonce UTXO input at index 0, signed with `SIGHASH_SINGLE | ANYONECANPAY | FORKID (0xC3)`. This locks the payment output (at output index 0) while allowing the client to append inputs and outputs freely. Then add the payment output.

**PayGateway**: just the base behaviour. Payment output, no nonce.

```ruby
# Pseudocode
class Gateway
  def build_template(route, config)
    tx = Transaction.new
    tx.add_output(payee: config.payee_locking_script_hex, amount: route.amount_sats)
    tx
  end
end

class ProofGateway < Gateway
  def build_template(route, config)
    tx = Transaction.new
    nonce = fetch_nonce  # from treasury
    # Input 0: nonce UTXO, signed with 0xC3
    # SIGHASH_SINGLE commits to output[0] only
    # ANYONECANPAY allows additional inputs
    tx.add_signed_input(nonce, key: @nonce_key, sighash: 0xC3)
    # Output 0: payment (locked by the 0xC3 signature)
    tx.add_output(payee: config.payee_locking_script_hex, amount: route.amount_sats)
    tx
  end
end

class PayGateway < Gateway
  # inherits build_template — just the payment output, no nonce
end
```

The client's job is identical regardless of scheme: add funding inputs, sign them, and either broadcast (BSV-proof) or hand to the server (BSV-pay). The delegator fits the same way in both flows — it receives the extended template and appends fee inputs.

### Why 0xC3 for the nonce signature

`SIGHASH_SINGLE | ANYONECANPAY | FORKID`:
- `SIGHASH_SINGLE`: commits only to `output[input_index]` — since the nonce is at input 0, the signature protects only output 0 (the payment). Additional outputs (change, etc.) can be added freely.
- `ANYONECANPAY`: excludes other inputs — funding inputs and fee inputs can be appended without invalidating the gateway's signature.
- `FORKID`: BSV fork ID flag (required).

Using `0xC1` (`SIGHASH_ALL | ANYONECANPAY`) would commit to ALL outputs, breaking the extensibility model.

## Multi-protocol Support

### HTTP headers

| Scheme | Challenge header | Proof header | Receipt header |
|--------|-----------------|--------------|----------------|
| BSV-pay (ours) | `Payment-Required` | `Payment-Signature` | `Payment-Response` |
| BSV-proof (merkleworks) | `X402-Challenge` | `X402-Proof` | — |

Our PayGateway uses the Coinbase v2 headers — the standard x402 ecosystem language. The ProofGateway uses the merkleworks `X402-*` headers. A server running both sends both:

```
HTTP/1.1 402 Payment Required
Payment-Required: <base64(v2 PaymentRequired JSON with BSV in accepts)>
X402-Challenge: <base64url(merkleworks challenge JSON)>
```

The `Payment-Required` challenge follows the Coinbase v2 structure:

```json
{
  "x402Version": 2,
  "resource": { "url": "/api/expensive" },
  "accepts": [
    {
      "scheme": "exact",
      "network": "bsv:main",
      "amount": "100",
      "asset": "BSV",
      "payTo": "1A1zP1...",
      "maxTimeoutSeconds": 60
    }
  ]
}
```

BSV appears in the `accepts` array alongside any other chains. A multi-chain server could offer USDC on Base and BSV in the same `Payment-Required` header.

### Gateway interface

Each gateway implements:

```ruby
#   #challenge_headers(rack_request, route) → Hash
#     Returns header name → value pairs for the 402 response.
#     A gateway may contribute to multiple headers.
#
#   #proof_header_names → Array<String>
#     The HTTP header names this gateway recognises as proofs.
#
#   #settle!(header_name, proof_payload, rack_request, route) → result
#     Verify and settle the proof. Raises X402::VerificationError on failure.
#     Returns a result object (with optional receipt headers).
```

### Middleware dispatch flow

```ruby
# Simplified — challenge issuance
def issue_challenge(rack_request, route)
  headers = {}
  config.gateways.each do |gw|
    gw.challenge_headers(rack_request, route).each do |name, value|
      headers[name] = value
    end
  end
  [402, headers, []]
end

# Simplified — proof dispatch
def verify_proof(rack_request, route)
  config.gateways.each do |gw|
    gw.proof_header_names.each do |header_name|
      proof = rack_request.get_header(header_name)
      next unless proof
      return gw.settle!(header_name, proof, rack_request, route)
    end
  end
  raise X402::Error, "no recognised proof header"
end
```

### Configuration

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  config.gateways = [
    X402::BSV::ProofGateway.new(
      nonce_key: "...",          # or wallet_url: "https://treasury.example.com"
      arc_url: "https://arc.taal.com",
      arc_api_key: "..."
    ),
    X402::BSV::PayGateway.new(
      arc_url: "https://arc.taal.com",
      arc_api_key: "..."
    )
  ]

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end
```

## Two BSV Schemes

### BSV-proof (merkleworks x402 spec)

Implements the merkleworks protocol. Client broadcasts, server checks mempool.

**Headers**: `X402-Challenge` / `X402-Proof`

**Challenge**: merkleworks JSON format including a pre-signed partial tx template (Profile B) with nonce UTXO at input 0 signed with `0xC3`, payment output at output 0, plus request binding metadata (method, path, query, headers hash, body hash), expiry, and `require_mempool_accept: true`.

**Client flow**: extend template with funding inputs → delegator adds fees → broadcast → retry with proof (txid + rawtx)

**Settlement flow**:
1. Decode proof JSON (echoed challenge + payment txid + rawtx)
2. Verify echoed challenge (hash, binding, expiry)
3. Decode raw tx
4. Verify nonce UTXO spent as input at index 0 (challenge binding)
5. Verify payment output (amount + payee)
6. Check mempool visibility via ARC
7. Return result

**Requires**: Treasury (for nonce provision + template signing) + ARC (for mempool queries).

**Why client broadcasts** (per Rui at merkleworks): Broadcasting is settlement, not authorisation. If the server broadcasts, it takes on transaction submission responsibility, retry/reconciliation logic, and mempool interaction state — pushing it towards a stateful payment processor. Client-side broadcast keeps the server stateless and HTTP authorisation cleanly decoupled from network settlement.

### BSV-pay (our BSV-native scheme)

Server broadcasts via ARC. Simpler flow, no nonces needed. Uses Coinbase v2 header spec.

**Headers**: `Payment-Required` / `Payment-Signature` / `Payment-Response`

**Challenge** (Coinbase v2 `PaymentRequired` structure):
```json
{
  "x402Version": 2,
  "resource": { "url": "/api/expensive" },
  "accepts": [
    {
      "scheme": "exact",
      "network": "bsv:main",
      "amount": "100",
      "asset": "BSV",
      "payTo": "1A1zP1...",
      "maxTimeoutSeconds": 60
    }
  ]
}
```

Includes a partial tx template with payment output only (no nonce). The client adds funding inputs, signs, and hands the completed tx to the server.

**Payment payload** (Coinbase v2 `PaymentPayload` structure with BSV-specific payload):
```json
{
  "x402Version": 2,
  "accepted": {
    "scheme": "exact",
    "network": "bsv:main",
    "amount": "100",
    "asset": "BSV",
    "payTo": "1A1zP1...",
    "maxTimeoutSeconds": 60
  },
  "payload": {
    "rawtx": "<hex-encoded raw transaction>",
    "txid": "<double-SHA256 of raw tx bytes>"
  }
}
```

**Settlement flow**:
1. Decode `Payment-Signature` header (base64 → PaymentPayload JSON)
2. Verify `accepted` matches a valid route
3. Decode raw tx from `payload.rawtx`
4. Verify payment output (amount + payee)
5. Broadcast to ARC
6. ARC 200 → return `Payment-Response` header with settlement result
7. ARC error → raise VerificationError (relay ARC response to client)

**No nonces needed**: ARC is the replay gate. Each tx can only be accepted once.

**No request binding needed**: ARC acceptance proves freshness.

**Requires**: ARC only. No treasury, no nonce provision.

**ARC as the settlement oracle**:
- ARC 200 OK → relay client request to application
- Anything else → relay ARC response to client

See: https://docs.bsvblockchain.org/important-concepts/details/spv/broadcasting

**Open question — timeout**: ARC could be slow. A `config.arc_timeout` with a sensible default (5s?) would let the middleware return 504 Gateway Timeout if ARC doesn't respond in time.

### Comparison

| | BSV-proof (merkleworks) | BSV-pay (ours) |
|---|---|---|
| Header spec | Merkleworks `X402-*` | Coinbase v2 `Payment-*` |
| Challenge header | `X402-Challenge` | `Payment-Required` |
| Proof header | `X402-Proof` | `Payment-Signature` |
| Receipt header | — | `Payment-Response` |
| Template contains | Nonce input (signed 0xC3) + payment output | Payment output only |
| Who broadcasts | Client | Server (via ARC) |
| Nonce needed | Yes (challenge binding) | No (ARC is replay gate) |
| Request binding | Yes (in challenge) | No (ARC acceptance = freshness) |
| Settlement check | Mempool visibility query | ARC broadcast response |
| Treasury needed | Yes (nonce provision + signing) | No |
| Minimum infrastructure | Treasury + ARC | ARC only |
| Ecosystem compatibility | Merkleworks BSV clients | Any x402 v2 client |

## File Changes

### New files
- `lib/x402/bsv.rb` — Module entry point
- `lib/x402/bsv/gateway.rb` — `X402::BSV::Gateway` base class (builds payment-output-only template)
- `lib/x402/bsv/proof_gateway.rb` — `X402::BSV::ProofGateway` (extends base, adds nonce, merkleworks settlement)
- `lib/x402/bsv/pay_gateway.rb` — `X402::BSV::PayGateway` (extends base, ARC broadcast settlement)

### Modified files
- `lib/x402/configuration.rb` — Replace `nonce_provider` + `arc_url`/`arc_api_key` with `gateways` array
- `lib/x402/middleware.rb` — Multi-gateway dispatch (poll for challenges, route proofs)
- `lib/x402/protocol/challenge.rb` — Challenge building moves into gateway
- `lib/x402/verification/pipeline.rb` — Pipeline moves into gateway
- `lib/x402.rb` — Require `x402/bsv`
- `DESIGN.md` — Update to reflect dispatcher architecture, template model, two schemes, ecosystem context

### Removed
- `lib/x402/verification/settlement_checks.rb` — Logic moves into gateway classes

### Specs
- New specs for `X402::BSV::Gateway`, `X402::BSV::ProofGateway`, `X402::BSV::PayGateway`
- Update middleware specs for multi-gateway dispatch
- Update configuration specs

## DESIGN.md Updates

1. **Component boundaries**: Gatekeeper (middleware, no keys), Gateway (holds keys, signs, settles), Treasury (external or local nonce service), Delegator (separate, not our concern).
2. **Unified template model**: all gateways produce partial tx templates. ProofGateway adds nonce at index 0 with 0xC3. PayGateway produces payment output only.
3. **Middleware as dispatcher**: no blockchain knowledge, polls gateways for challenges, routes proofs.
4. **Multi-protocol headers**: payment content negotiation across ecosystems.
5. **Two BSV schemes**: BSV-proof (merkleworks) and BSV-pay (ours). Same template model, different settlement.
6. **ARC as settlement oracle**: authoritative for BSV-pay.
7. **Ecosystem context**: merkleworks BSV spec, Coinbase v2 broad ecosystem, our position.

## Verification

1. `bundle exec rake spec` — all tests pass
2. `bundle exec rubocop` — no lint violations
3. Boundary test: could someone write `X402::EVM::Gateway` implementing `challenge_headers`, `proof_header_names`, and `settle!` without touching `lib/x402/`? Yes.

## Future Considerations (deferred)

- **Coinbase facilitator pattern**: verify-then-settle two-step. Our PayGateway could support this — verify tx structure first, serve resource, broadcast to ARC after.
- **Extensions mechanism**: gas sponsoring, request binding as extension, custom auth schemes.
- **Multi-chain accepts array**: BSV alongside EVM chains in the same `Payment-Required` header — now possible since we use the v2 structure.
- **Runar contract AST**: client sends ContractNode AST, gateway compiles via runar. A future scheme on the same dispatcher.
- **Header size**: standard BSV payment txs are ~400-600 bytes base64-encoded, well within 8KB+ server limits. Multipart form data for POST requests if this becomes an issue.
