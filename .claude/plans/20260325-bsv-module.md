# Plan: X402::BSV Module — Responsibilities and Interface

## Context

The codebase has BSV-specific logic in `X402::Verification::SettlementChecks` that needs to move behind an `X402::BSV` boundary. Through analysis of both the merkleworks reference implementation and the Coinbase x402 ecosystem, the middleware's role has clarified: it is a **pure dispatcher** with no blockchain knowledge. Gateways are pluggable backends that handle chain-specific settlement.

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

**Our position**: Implement merkleworks first for BSV compatibility. Add our own BSV-native scheme. Structure the middleware so adding Coinbase-compatible gateways is possible without architectural changes. Coinbase will gatekeep BSV from their ecosystem — our conformance is about making it easy for others to integrate BSV as a supported network.

## Architecture: Middleware as Dispatcher

### The middleware knows nothing about blockchains

The Rack middleware is a protocol-level dispatcher. It:

1. **On request**: polls each configured gateway for challenge headers, returns all of them in the 402 response
2. **On proof**: checks which proof/payment header the client sent, dispatches to the matching gateway
3. **On result**: the gateway returns allow/deny — the middleware serves or rejects accordingly

The middleware never decodes transactions, checks mempool, broadcasts, or interacts with any blockchain network. It manages HTTP headers, route matching, and dispatch. Everything else is the gateway's job.

### Multi-protocol support via HTTP headers

| Scheme | Challenge header | Proof header | Receipt header |
|--------|-----------------|--------------|----------------|
| BSV-proof (merkleworks) | `X402-Challenge` | `X402-Proof` | — |
| BSV-pay (ours) | `X402-Challenge` | `X402-Pay` | TBD |
| Coinbase v2 (future) | `Payment-Required` | `Payment-Signature` | `Payment-Response` |

A server can send **multiple challenge headers** simultaneously. The client picks the one it can satisfy. This is payment content negotiation.

```
HTTP/1.1 402 Payment Required
X402-Challenge: <base64url(merkleworks challenge JSON)>
Payment-Required: <base64url(coinbase v2 requirements JSON)>
```

For broader ecosystem compatibility, a BSV gateway could also contribute to a `Payment-Required` header with BSV in the `accepts` array alongside other chains.

### Gateway interface

Each gateway implements:

```ruby
# The interface every gateway must implement:
#
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

Note: `challenge_headers` returns a Hash (not a single header) because a gateway might contribute to both `X402-Challenge` and `Payment-Required`. And `proof_header_names` is an array because a gateway might accept both `X402-Proof` and `X402-Pay`.

### Configuration

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  config.gateways = [
    X402::BSV::ProofGateway.new(
      wallet_url: "https://wallet.example.com",
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

## Two BSV Schemes

### BSV-proof (merkleworks x402 spec)

Implements the merkleworks protocol. Client broadcasts, server checks mempool.

**Headers**: `X402-Challenge` / `X402-Proof`

**Challenge** (merkleworks JSON format):
- Nonce UTXO (txid, vout, satoshis, locking_script_hex) — fetched from remote wallet
- Amount, payee locking script
- Request binding (method, path, query, headers hash, body hash)
- Expiry, `require_mempool_accept: true`

**Settlement flow**:
1. Decode proof JSON (echoed challenge + payment txid + rawtx)
2. Verify echoed challenge (hash, binding, expiry)
3. Decode raw tx
4. Verify nonce UTXO spent as input (challenge binding)
5. Verify payment output (amount + payee)
6. Check mempool visibility via ARC
7. Return result

**Requires**: Remote wallet for nonce provision, ARC for mempool queries.

**Nonce UTXOs**:
- 1-satoshi UTXOs issued by the gateway's remote wallet
- Single-spend provides replay protection + challenge binding
- Nonce script structure is the remote wallet's concern
- Timelock return: unused nonces auto-return via timelocked script path
- No pool, no lease table — blockchain is the state

### BSV-pay (our BSV-native scheme)

Server broadcasts via ARC. Simpler flow, no nonces needed.

**Headers**: `X402-Pay` (proof header TBD for challenge — may share `X402-Challenge` or use `Payment-Required`)

**Proof payload** (our canonical JSON):
```json
{
  "rawtx": "<hex-encoded raw transaction>",
  "txid": "<double-SHA256 of raw tx bytes>"
}
```

The txid is redundant (derivable from rawtx) but useful for logging/receipts without deserialising.

**Settlement flow**:
1. Decode proof JSON
2. Verify payment output (amount + payee) from the raw tx
3. Broadcast to ARC
4. ARC 200 → return success result
5. ARC error → raise VerificationError (relay ARC response to client)

**No nonces needed**: ARC is the replay gate. Each tx can only be accepted once. If a client submits the same tx twice, ARC rejects the second broadcast. The tx itself is the replay protection.

**No request binding needed**: ARC acceptance proves freshness. The server doesn't need to bind the payment to a specific request — it just needs to know it received a valid, previously-unseen payment of the right amount to the right address.

**Requires**: ARC only. No remote wallet, no nonce provision.

**ARC as the settlement oracle**: The middleware treats the ARC response as authoritative:
- ARC 200 OK → relay client request to application
- Anything else → relay ARC response to client

See: https://docs.bsvblockchain.org/important-concepts/details/spv/broadcasting

**Open question — timeout**: ARC could be slow. A `config.arc_timeout` with a sensible default (5s?) would let the middleware return 504 Gateway Timeout if ARC doesn't respond in time.

**Header size**: Standard BSV payment transactions (few inputs, couple of outputs) are a few hundred bytes. Base64 adds ~33% overhead. Typical payment tx = ~400-600 bytes in a header, well within server limits (8KB+). Exotic transactions could be a problem but aren't relevant to micropayments.

### Comparison

| | BSV-proof (merkleworks) | BSV-pay (ours) |
|--|--|--|
| Challenge header | `X402-Challenge` | TBD |
| Proof header | `X402-Proof` | `X402-Pay` |
| Who broadcasts | Client | Server (via ARC) |
| Nonce needed | Yes (challenge binding) | No (ARC is replay gate) |
| Request binding | Yes (in challenge) | No (ARC acceptance = freshness) |
| Settlement check | Mempool visibility query | ARC broadcast response |
| Remote wallet needed | Yes (nonce provision) | No |
| Minimum infrastructure | Wallet + ARC | ARC only |

## The Three-Actor Model (BSV)

1. **Gatekeeper** (our Rack middleware) — dispatches challenges and proofs
2. **Delegator** (fee sponsor, separate service) — adds fee inputs to client-constructed partial txs
3. **Client** (browser + CWI wallet) — constructs partial tx, gets fees from delegator, presents proof/payment

The middleware only participates at the HTTP boundary. The delegator is between the client and the network — the middleware never talks to it.

## File Changes

### New files
- `lib/x402/bsv.rb` — Module entry point
- `lib/x402/bsv/proof_gateway.rb` — `X402::BSV::ProofGateway` (merkleworks BSV-proof)
- `lib/x402/bsv/pay_gateway.rb` — `X402::BSV::PayGateway` (BSV-pay)

### Modified files
- `lib/x402/configuration.rb` — Replace `nonce_provider` + `arc_url`/`arc_api_key` with `gateways` array
- `lib/x402/middleware.rb` — Multi-gateway dispatch (poll for challenges, route proofs)
- `lib/x402/protocol/challenge.rb` — Challenge building moves into gateway (BSV-specific JSON structure)
- `lib/x402/verification/pipeline.rb` — Pipeline moves into gateway (BSV-specific verification)
- `lib/x402.rb` — Require `x402/bsv`
- `DESIGN.md` — Update to reflect dispatcher architecture, two schemes, ecosystem context

### Removed
- `lib/x402/verification/settlement_checks.rb` — Logic moves into `X402::BSV::ProofGateway`

### Specs
- New specs for `X402::BSV::ProofGateway` and `X402::BSV::PayGateway`
- Update middleware specs for multi-gateway dispatch
- Update configuration specs

## DESIGN.md Updates

1. **Middleware as dispatcher**: no blockchain knowledge, polls gateways for challenges, routes proofs to matching gateway.
2. **Multi-protocol headers**: payment content negotiation across ecosystems.
3. **Gateway interface**: `challenge_headers()`, `proof_header_names`, `settle!()`.
4. **Two BSV schemes**: BSV-proof (merkleworks, client broadcasts, nonce-bound) and BSV-pay (server broadcasts via ARC, no nonces).
5. **ARC as settlement oracle**: ARC response is authoritative for BSV-pay. No mempool checking, no nonce tracking.
6. **Ecosystem context**: merkleworks BSV spec, Coinbase v2 broad ecosystem, our position between them.
7. **Three-actor model**: Gatekeeper (middleware), Delegator (fee sponsor), Client. Middleware only at HTTP boundary.

## Verification

1. `bundle exec rake spec` — all tests pass
2. `bundle exec rubocop` — no lint violations
3. Boundary test: could someone write `X402::EVM::Gateway` implementing `challenge_headers`, `proof_header_names`, and `settle!` without touching `lib/x402/`? Yes.

## Future Considerations (deferred)

- **Coinbase facilitator pattern**: verify-then-settle two-step. Could be faked for BSV if needed.
- **Extensions mechanism**: gas sponsoring, request binding as extension, custom auth schemes.
- **`Payment-Required` accepts array**: BSV alongside EVM chains in a single header.
- **Runar contract AST**: client sends ContractNode AST, gateway compiles via runar. A future scheme (`bsv:contract`?) on the same dispatcher.
- **Multipart form data**: for POST requests with large transaction payloads if header size becomes an issue.
