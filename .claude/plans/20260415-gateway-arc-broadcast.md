# Plan: Gateway must broadcast payment tx before forwarding to app (#148)

## Context

BRC105Gateway and BRC121Gateway call `wallet.internalize_action()` but never broadcast the tx to ARC. With the bsv-x402 client's `noSend: true` change, the payment tx is never on-chain, yet the app receives the request as if settled. This led to a real incident in x402-doom where a player received on-chain sats for free (sgbett/x402-doom#203).

**Key insight:** ARC is idempotent for the same txid — broadcasting the same tx twice returns the current status (SEEN_ON_NETWORK, MINED), not a double-spend error. So the server should *always* broadcast, regardless of whether the client already did. Both can broadcast safely.

**Economic invariant:** "No credit without on-chain settlement."

## Approach

Add a `broadcast_beef` method to the Ruby SDK's ARC client, then have BRC105Gateway and BRC121Gateway broadcast the BEEF to ARC after validation but before internalization. Broadcast failure = reject the request (per HLR acceptance criteria).

### Why BEEF, not raw tx or EF

The client may have used `noSend: true`, meaning ARC hasn't seen the parent transactions. BEEF includes the full SPV ancestry, so ARC can validate without fetching parents. Raw tx or EF would fail with `460 Not extended format` or `missing input scripts`.

### Why broadcast before internalize (not after)

If we internalize first and broadcast fails, the wallet has a dead record for a tx that never went on-chain. By broadcasting first, we only internalize payments that are confirmed on-network. If broadcast fails, nothing was internalized, so there's no accounting mess.

### Order of operations (both gateways)

1. Validate headers, parse BEEF, verify payment output (existing)
2. Check replay protection — txid_store / prefix_store (existing)
3. **Broadcast BEEF to ARC (NEW)** — fail = reject request
4. Internalize into wallet (existing)
5. Forward to app (existing)

## Steps

### Step 1: Add `broadcast_beef` to `BSV::Network::ARC`

**File:** `/opt/ruby/bsv-ruby-sdk/gem/bsv-sdk/lib/bsv/network/arc.rb`

Add alongside existing `broadcast` method:

```ruby
def broadcast_beef(beef_bytes, wait_for: nil, skip_fee_validation: nil, skip_script_validation: nil)
  uri = URI("#{@url}/v1/tx")
  request = build_post_request(uri, wait_for: wait_for,
                                    skip_fee_validation: skip_fee_validation,
                                    skip_script_validation: skip_script_validation)
  request['Content-Type'] = 'application/octet-stream'
  request.body = beef_bytes.b

  response = execute(uri, request)
  handle_broadcast_response(response)
end
```

Reuses `build_post_request` (which sets JSON content-type), then overrides to `application/octet-stream`. Response handling is identical — ARC returns the same JSON response structure regardless of input format.

**Spec:** `/opt/ruby/bsv-ruby-sdk/gem/bsv-sdk/spec/bsv/network/arc_spec.rb` — mirror existing `#broadcast` tests for content-type, binary body, wait_for header, error handling.

### Step 2: Update BRC121Gateway — accept `arc_client`, broadcast BEEF

**File:** `lib/x402/bsv/brc121_gateway.rb`

Constructor: add `arc_client: nil` keyword, store as `@arc_client`.

In `settle!`, insert `broadcast_to_arc!(headers["x-bsv-beef"])` after `verify_payment_output!` and `check_txid_unique!`, but BEFORE `internalize_payment!`:

```ruby
paid_sats = verify_payment_output!(subject_tx, output_index, required_sats)

broadcast_to_arc!(headers["x-bsv-beef"])  # NEW — on-chain before internalize

result = internalize_payment!(...)
```

New private method:

```ruby
def broadcast_to_arc!(beef_b64)
  return unless @arc_client

  beef_bytes = Base64.strict_decode64(beef_b64)
  @arc_client.broadcast_beef(beef_bytes)
rescue ::BSV::Network::BroadcastError => e
  raise VerificationError.new("ARC broadcast failed: #{e.message}", status: 402)
rescue StandardError => e
  logger.error "[brc121] ARC broadcast error: #{e.class}: #{e.message}"
  raise VerificationError.new("payment broadcast failed", status: 402)
end
```

Broadcast failure raises `VerificationError` → middleware returns 402 → client retries.

### Step 3: Update BRC105Gateway — same pattern

**File:** `lib/x402/bsv/brc105_gateway.rb`

Constructor: add `arc_client: nil`, store as `@arc_client`.

In `settle!`, insert broadcast after `verify_payment_output!` and `consume_prefix!`, before `internalize_payment!`.

Same `broadcast_to_arc!` method with `[brc105]` log tag.

### Step 4: Update Configuration to inject `arc_client`

**File:** `lib/x402/configuration.rb`

- Add `arc_client` to `BRC105_GATEWAY_KNOWN_OPTS` and `BRC121_GATEWAY_KNOWN_OPTS`
- In `build_brc105_gateway`: add `arc_client: options[:arc_client] || shared_arc_client`
- In `build_brc121_gateway`: add `arc_client: options[:arc_client] || shared_arc_client`

Same `options[:arc_client] || shared_arc_client` pattern already used by `build_pay_gateway`.

### Step 5: Tests

**BRC121Gateway spec** (`spec/x402/bsv/brc121_gateway_spec.rb`):
- Add `arc_client` double to gateway construction
- "broadcasts BEEF to ARC after validation"
- "rejects when ARC broadcast fails" (BroadcastError → VerificationError 402)
- "skips broadcast when arc_client is nil" (backward compat)
- "succeeds when ARC returns SEEN_ON_NETWORK" (idempotent re-broadcast)

**BRC105Gateway spec** (`spec/x402/bsv/brc105_gateway_spec.rb`): same pattern.

**Configuration spec** (`spec/x402/configuration_spec.rb`):
- "injects shared_arc_client into BRC105Gateway"
- "injects shared_arc_client into BRC121Gateway"
- "allows per-gateway arc_client override"

## Dependency order

```
Step 1 (SDK: broadcast_beef)  ← separate repo, separate commit
    ↓
Steps 2 + 3 (gateway changes, parallel)
    ↓
Step 4 (configuration wiring)
    ↓
Step 5 (tests alongside each step)
```

## Files to modify

| File | Change |
|------|--------|
| `/opt/ruby/bsv-ruby-sdk/gem/bsv-sdk/lib/bsv/network/arc.rb` | Add `broadcast_beef` method |
| `/opt/ruby/bsv-ruby-sdk/gem/bsv-sdk/spec/bsv/network/arc_spec.rb` | Spec for `broadcast_beef` |
| `lib/x402/bsv/brc121_gateway.rb` | Accept `arc_client`, add broadcast step |
| `lib/x402/bsv/brc105_gateway.rb` | Accept `arc_client`, add broadcast step |
| `lib/x402/configuration.rb` | Inject `arc_client` into both gateways |
| `spec/x402/bsv/brc121_gateway_spec.rb` | Broadcast specs |
| `spec/x402/bsv/brc105_gateway_spec.rb` | Broadcast specs |
| `spec/x402/configuration_spec.rb` | Wiring specs |

## Verification

1. `cd /opt/ruby/bsv-ruby-sdk && bundle exec rspec spec/bsv/network/arc_spec.rb` — SDK broadcast_beef specs
2. `cd /opt/ruby/x402-rack && bundle exec rake` — full suite (specs + rubocop)
3. Manual: configure BRC121Gateway with a real ARC client and submit a payment — verify the tx appears on WhatsOnChain
