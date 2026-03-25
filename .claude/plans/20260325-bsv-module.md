# Plan: X402::BSV Module — Responsibilities and Interface

## Context

The codebase has BSV-specific logic in `X402::Verification::SettlementChecks` that needs to move behind an `X402::BSV` boundary. Through analysis of both the merkleworks reference implementation and the Coinbase x402 ecosystem, the middleware's role has clarified: it is a **pure dispatcher** with no blockchain knowledge. Gateways are pluggable backends that handle chain-specific settlement.

## Architecture: Middleware as Dispatcher

### The middleware knows nothing about blockchains

The Rack middleware is a protocol-level dispatcher. It:

1. **On request**: polls each configured gateway for challenge headers, returns all of them in the 402 response
2. **On proof**: checks which proof/payment header the client sent, dispatches to the matching gateway
3. **On result**: the gateway returns allow/deny — the middleware serves or rejects accordingly

The middleware never decodes transactions, checks mempool, broadcasts, or interacts with any blockchain network. It manages HTTP headers, route matching, and request binding. Everything else is the gateway's job.

### Multi-protocol support via HTTP headers

Different x402 ecosystems use different HTTP headers:

| Ecosystem | Challenge header | Proof header |
|-----------|-----------------|--------------|
| Merkleworks BSV | `X402-Challenge` | `X402-Proof` |
| Coinbase v2 | `Payment-Required` | `Payment-Signature` |
| BSV-direct (ours) | TBD | TBD |

A server can send **multiple challenge headers** simultaneously. The client picks the one it can satisfy and responds with the corresponding proof header. This is payment content negotiation — the same pattern as `Accept:`/`Content-Type:`.

```
HTTP/1.1 402 Payment Required
X402-Challenge: <base64url(merkleworks challenge JSON)>
Payment-Required: <base64url(coinbase v2 requirements JSON)>
```

The client responds with whichever it supports:
```
X402-Proof: <base64url(merkleworks proof JSON)>
```
or:
```
Payment-Signature: <base64url(coinbase v2 signed payload JSON)>
```

### Gateway interface

Each gateway implements three methods:

```ruby
# The interface every gateway must implement:
#
#   #challenge_header_name → String
#     The HTTP header name this gateway uses for challenges (e.g. "X402-Challenge")
#
#   #proof_header_name → String
#     The HTTP header name this gateway reads for proofs (e.g. "X402-Proof")
#
#   #challenge(rack_request, route) → String
#     Build the challenge payload (base64url-encoded) for this route
#
#   #settle!(proof_payload, rack_request, route) → result
#     Verify and settle the proof. Raises X402::VerificationError on failure.
#     Returns a result object the middleware can use for receipt headers.
```

### Configuration

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  config.gateways = [
    X402::BSV::Gateway.new(
      wallet_url: "https://wallet.example.com",
      arc_url: "https://arc.taal.com",
      arc_api_key: "..."
    )
    # Could add more:
    # X402::EVM::Gateway.new(...)
  ]

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end
```

### Middleware dispatch flow

```ruby
# Simplified — challenge issuance
def issue_challenge(rack_request, route)
  headers = {}
  config.gateways.each do |gw|
    headers[gw.challenge_header_name] = gw.challenge(rack_request, route)
  end
  [402, headers, []]
end

# Simplified — proof verification
def verify_proof(rack_request, route)
  config.gateways.each do |gw|
    proof = rack_request.get_header(gw.proof_header_name)
    next unless proof
    return gw.settle!(proof, rack_request, route)
  end
  raise X402::Error, "no recognised proof header"
end
```

## X402::BSV::Gateway

The BSV gateway handles merkleworks-compatible settlement. It owns all BSV-specific logic: nonce provision, transaction decoding, verification, and ARC interaction.

### Challenge

Fetches a 1-sat nonce UTXO from the remote wallet, builds the merkleworks challenge JSON (nonce ref, amount, payee, binding, expiry), returns it base64url-encoded.

```ruby
gateway.challenge_header_name  # => "X402-Challenge"
gateway.proof_header_name      # => "X402-Proof"
gateway.challenge(rack_request, route)  # => base64url(challenge JSON)
```

### Settlement — two modes

Both modes share the same verification steps (decode tx, check nonce input, check payment output). They differ in who broadcasts.

**Proof mode** (merkleworks spec, implemented first):
- Client broadcasts before retrying
- Gateway verifies tx structure + checks mempool visibility via ARC
- Challenge includes `require_mempool_accept: true`

**Direct mode** (BSV-native, name TBD):
- Client hands raw tx to server without broadcasting
- Gateway verifies tx structure + broadcasts via ARC
- Server has settlement certainty because it broadcast

```ruby
gateway.settle!(proof_payload, rack_request, route)
# 1. Decode base64url proof JSON
# 2. Reconstruct and verify the echoed challenge (hash, binding, expiry)
# 3. Decode raw tx from proof
# 4. Verify nonce UTXO spent as input (binding)
# 5. Verify payment output (amount + payee)
# 6. Proof mode: check mempool via ARC / Direct mode: broadcast via ARC
# 7. Return result for receipt headers
```

### Nonce UTXOs

- 1-satoshi UTXOs issued by the gateway's remote wallet
- Single-spend (UTXO consumption) provides replay protection at the network layer
- The nonce script structure is the **remote wallet's concern**, not the gateway's
- The gateway passes nonce details through opaquely (txid, vout, satoshis, locking_script_hex)
- Timelock return: unused nonces auto-return to the wallet via a timelocked script path

### No pool, no lease table

The blockchain IS the state:
- **"Lease"** = the nonce UTXO exists on-chain with a timelock return path
- **"Release"** = timelock expires, funds auto-return (blockchain handles it)
- **"Mark spent"** = client spends the nonce in the payment tx (Bitcoin's single-spend guarantee)

### The three-actor model (BSV settlement)

1. **Gatekeeper** (our Rack middleware) — dispatches challenges and proofs
2. **Delegator** (fee sponsor, separate service) — adds fee inputs to client-constructed partial txs
3. **Client** (browser + CWI wallet) — constructs partial tx, gets fees from delegator, presents proof

The middleware only participates at the HTTP boundary. The delegator is between the client and the network — the middleware never talks to it.

## File Changes

### New files
- `lib/x402/bsv.rb` — Module entry point
- `lib/x402/bsv/gateway.rb` — `X402::BSV::Gateway` (challenge + settle!)

### Modified files
- `lib/x402/configuration.rb` — Replace `nonce_provider` + `arc_url`/`arc_api_key` with `gateways` array
- `lib/x402/middleware.rb` — Multi-gateway dispatch (poll for challenges, route proofs)
- `lib/x402/protocol/challenge.rb` — Challenge building moves into gateway (BSV-specific JSON structure)
- `lib/x402/verification/pipeline.rb` — Pipeline moves into gateway (BSV-specific verification)
- `lib/x402.rb` — Require `x402/bsv`
- `DESIGN.md` — Update to reflect dispatcher architecture, multi-protocol, settlement modes

### Removed
- `lib/x402/verification/settlement_checks.rb` — Logic moves into `X402::BSV::Gateway`

### Specs
- New specs for `X402::BSV::Gateway`
- Update middleware specs for multi-gateway dispatch
- Update configuration specs

## DESIGN.md Updates

1. **Middleware as dispatcher**: no blockchain knowledge, polls gateways for challenges, routes proofs to matching gateway.
2. **Multi-protocol support**: multiple challenge/proof headers, payment content negotiation.
3. **Gateway interface**: `challenge_header_name`, `proof_header_name`, `challenge()`, `settle!()`.
4. **BSV gateway**: nonce provision, tx verification, ARC interaction. Two settlement modes (proof + direct).
5. **Onchain nonce model**: replace staged pool evolution with timelocked 1-sat UTXOs, blockchain as state.
6. **Three-actor model**: Gatekeeper (middleware), Delegator (fee sponsor), Client. Middleware only at HTTP boundary.

## Verification

1. `bundle exec rake spec` — all tests pass
2. `bundle exec rubocop` — no lint violations
3. Boundary test: could someone write `X402::EVM::Gateway` implementing `challenge_header_name`, `proof_header_name`, `challenge()`, and `settle!()` without touching `lib/x402/`? Yes.
