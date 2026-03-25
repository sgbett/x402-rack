# Plan: X402::BSV Module — Responsibilities and Interface

## Context

The codebase has BSV-specific logic in `X402::Verification::SettlementChecks` that needs to move behind an `X402::BSV` boundary. Simultaneously, the nonce lifecycle model and the middleware's role in the settlement flow need clarifying based on the x402 spec and reference implementation.

### What we learned from the reference implementation

The x402 settlement flow has **three actors**:

1. **Gatekeeper** (our Rack middleware) — issues 402 challenges, verifies proofs
2. **Delegator** (fee sponsor) — adds fee inputs to client-constructed partial txs, signs only its fee inputs
3. **Client** (browser + CWI wallet) — constructs partial tx, sends to delegator, broadcasts, retries with proof

**The settlement flow (Profile A):**

1. Client requests protected resource
2. Gateway responds 402 with challenge (nonce UTXO ref, amount, payee, binding, expiry)
3. **Client** builds partial tx: spends nonce UTXO + creates payment output (signs with `SIGHASH_ALL | ANYONECANPAY | FORKID`)
4. Client submits partial tx to delegator
5. Delegator validates, adds fee inputs from its pool
6. Delegator returns completed, signed transaction to client
7. Client retries original request with `X402-Proof` header containing the raw tx
8. **Gateway verifies proof** (nonce spent? payment output present?)
9. **Gateway broadcasts via ARC** — ARC confirms acceptance → serve the resource

**Key insight: the middleware participates in steps 2, 8, and 9.** Steps 3-6 are between the client and delegator. The middleware issues challenge data, verifies proofs, and **broadcasts the transaction itself**.

**Why the server broadcasts, not the client:** In BSV, the payee (seller) broadcasts because they need settlement certainty. The client hands the signed raw tx to the server as proof. The server verifies the tx structure, submits it to ARC, and ARC confirms whether the network accepts it. The server never trusts the client to have broadcast — it has the raw tx and settles directly.

Note: the reference implementation (merkleworks) has the client broadcasting (step 7 in their 9-step flow). We believe server-side broadcast is the correct BSV model and intend to discuss this with merkleworks. The middleware supports both — `settle!` can check mempool for an already-broadcast tx OR broadcast it directly.

### Nonce UTXOs

- 1-satoshi UTXOs issued by the gateway's wallet
- Single-spend (UTXO consumption) provides replay protection at the network layer
- The nonce script structure is the **remote wallet's concern**, not the middleware's
- The middleware passes nonce details through opaquely (txid, vout, satoshis, locking_script_hex)
- Timelock return: if the client doesn't spend the nonce, it auto-returns to the wallet via a timelocked script path. The middleware doesn't track this.

### No pool, no lease table

The blockchain IS the state:
- **"Lease"** = the nonce UTXO exists on-chain with a timelock return path
- **"Release"** = timelock expires, funds auto-return (blockchain handles it)
- **"Mark spent"** = client spends the nonce in the payment tx (Bitcoin's single-spend guarantee)
- The middleware never tracks nonce state. No pool. No lease table. No release callbacks.

### Profile B (future)

The reference mentions Profile B where "the gateway provides a pre-signed payment template". This simplifies the client but adds work at challenge time. We'll design the interface so Profile B can be added later without restructuring, but start with Profile A.

## X402::BSV Interface

`X402::BSV` is the bridge between the protocol layer and the BSV network. One object, two interfaces:

### 1. Nonce Provision

Called when building a challenge (step 2). Fetches a 1-sat nonce UTXO from the remote wallet.

```ruby
# Returns: { txid:, vout:, satoshis:, locking_script_hex: }
gateway.fetch_nonce(rack_request)
```

This replaces the raw `nonce_provider` callable on Configuration. The protocol layer calls `config.network.fetch_nonce(request)` instead.

### 2. Settlement (verify + broadcast)

Called when the client presents a proof (steps 8-9). Verifies the tx structure, then broadcasts via ARC for settlement certainty.

```ruby
# Raises X402::VerificationError on failure
# Returns: decoded transaction object
gateway.settle!(proof, challenge, route)
```

The settlement sequence:
1. Decode the raw tx from the proof
2. Verify txid matches the proof's claim
3. Verify nonce UTXO is spent as an input (binding)
4. Verify payment output pays the payee enough (payment)
5. **Broadcast to ARC** — this is the settlement step, not optional
6. Return the decoded transaction (for receipt headers)

Broadcast is integral to settlement, not a separate "if configured" step. The server is the payee — it broadcasts because it needs certainty that the network accepted the tx.

**Open question — who broadcasts?** The reference implementation has the **client** broadcasting before submitting the proof, with the server only checking mempool visibility. Our position is that the **server** should broadcast (standard BSV payee convention). In practice, `settle!` could do both: check mempool first (in case client already broadcast), broadcast if not yet visible. To be discussed with merkleworks.

### Protocol-layer abstraction

The protocol layer depends on a `network` object with two methods:

```ruby
# The interface X402::BSV::Gateway implements (and X402::Anything::Gateway could implement)
#   #fetch_nonce(rack_request) → Hash
#   #settle!(proof, challenge, route) → transaction
```

Configuration changes from:
```ruby
config.nonce_provider = ->(req) { ... }
config.arc_url = "..."
```
To:
```ruby
config.network = X402::BSV::Gateway.new(
  wallet_url: "https://wallet.example.com",
  arc_url: "https://arc.taal.com",
  arc_api_key: "..."
)
```

BSV-specific settings (`arc_url`, `arc_api_key`, `wallet_url`) live in `X402::BSV::Gateway`, not in `X402::Configuration`.

## File Changes

### New files
- `lib/x402/bsv.rb` — Module entry point
- `lib/x402/bsv/gateway.rb` — `X402::BSV::Gateway` (implements fetch_nonce + settle!)

### Modified files
- `lib/x402/configuration.rb` — Replace `nonce_provider` + `arc_url`/`arc_api_key` with `network` attribute
- `lib/x402/protocol/challenge.rb` — Call `config.network.fetch_nonce` instead of `config.nonce_provider.call`
- `lib/x402/verification/pipeline.rb` — Call `config.network.settle!` instead of `SettlementChecks.*`
- `lib/x402.rb` — Require `x402/bsv`
- `DESIGN.md` — Update to reflect onchain nonce model, three-actor flow, Profile A/B

### Removed
- `lib/x402/verification/settlement_checks.rb` — Logic moves into `X402::BSV::Gateway#settle!`

### Specs
- New specs for `X402::BSV::Gateway`
- Update pipeline specs to use network interface
- Update configuration specs
- Update challenge specs

## DESIGN.md Updates

1. **Replace the nonce provider staged evolution** (Echo → Pool → Local) with the onchain model: remote wallet mints timelocked 1-sat UTXOs, blockchain handles all state.
2. **Add the three-actor model** (Gatekeeper, Delegator, Client) with the settlement flow.
3. **Clarify the middleware's role**: steps 2, 8, and 9. Challenge issuance, proof verification, and settlement broadcast.
4. **Note Profile A vs B**: starting with A, interface designed to support B later.
5. **Remove stages 2/3** as an expected path. Acknowledge pluggable `network` interface for exotic deployments.
6. **Server-side broadcast**: document the BSV convention that the payee broadcasts and the divergence from the reference implementation.

## Verification

1. `bundle exec rake spec` — all tests pass
2. `bundle exec rubocop` — no lint violations
3. Boundary test: could someone write `X402::Solana::Gateway` implementing `fetch_nonce` and `settle!` without touching `lib/x402/`? Yes.
