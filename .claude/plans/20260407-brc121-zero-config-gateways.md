# Gateway strategy: BRC-121 + PayGateway as zero-config defaults, BRC-105 future

## Context

x402-rack currently ships three gateways: `PayGateway` (Coinbase v2), `ProofGateway` (merkleworks, experimental), and `BRC105Gateway` (BSV Association). Re-reading the BRC-105 spec confirms it has **no standalone mode** — it requires BRC-103 mutual authentication per §3, §5.1, and §7.1. Our `BRC105Gateway` only works today because of issue #101's `HTTP_X_BSV_AUTH_IDENTITY_KEY` fallback, which is a non-spec stopgap. x402-doom depends on this stopgap.

Meanwhile **BRC-121 ("Simple 402 Payments")** has emerged as the BSV ecosystem's blessed simple HTTP payment protocol: stateless server, BRC-100 wallet handles validation and replay detection via `internalizeAction` + `isMerge`, no PrefixStore, no challenge_secret, no nonce store.

### Gateway classification

| Gateway | Setup required | Status |
|---------|----------------|--------|
| `PayGateway` (Coinbase v2) | None — works zero-config | Stable |
| `BRC121Gateway` (new) | None — works zero-config | New |
| `BRC105Gateway` | Requires BRC-103 middleware OR custom instrumentation (e.g. doom) | Transitional |
| `ProofGateway` (merkleworks) | Experimental | Under development |

`PayGateway` and `BRC121Gateway` are the two gateways that work out of the box. Both should be enabled by default.

### Red lines (from user)
1. BRC-105 has no standalone mode — accept this and plan around it
2. Don't break x402-doom — it uses `BRC105Gateway` as-is today (with the #101 stopgap)
3. We need BRC-121 support
4. Plug-and-play defaults: install gem → restore/create wallet → set protected URLs → done
5. No "recommended default" framing — `PayGateway` and `BRC121Gateway` are simply the two zero-config gateways

### Goal
Add BRC-121 as a new zero-config gateway alongside PayGateway, provide a Rake task to set up or restore the server wallet (without nuking existing wallets), and keep BRC105Gateway running as-is until proper BRC-103 middleware lands.

## Approach — six phases, each non-breaking (this plan covers Phases 1–4)

### Phase 1 — Add `BRC121Gateway` (additive)

New `X402::BSV::BRC121Gateway` implementing the BRC-121 spec (https://hub.bsvblockchain.org/brc/payments/0121).

**Constructor:**
```ruby
BRC121Gateway.new(wallet:)
```

Single dependency: a duck-typed BRC-100 wallet responding to `#internalize_action(...)` and `#get_public_key(identity_key: true)`.

**`challenge_headers(rack_request, route)`** returns:
- `x-bsv-sats` — required satoshi amount
- `x-bsv-server` — server's identity public key (compressed hex, from `wallet.get_public_key(identity_key: true)`)

**`proof_header_names`** → `["x-bsv-beef"]`

**`settle!(_header_name, _proof_payload, rack_request, route)`:**
1. Check all five client headers present (`x-bsv-beef`, `x-bsv-sender`, `x-bsv-nonce`, `x-bsv-time`, `x-bsv-vout`) — raise `VerificationError(402)` on missing
2. Validate `x-bsv-time` is within 30s of server clock (spec §5 step 2) — raise `VerificationError(402)` if stale
3. Decode BEEF transaction from `x-bsv-beef`
4. Call `wallet.internalize_action(...)` with payment remittance:
   - `derivationPrefix` from `x-bsv-nonce`
   - `derivationSuffix` = `Base64.strict_encode64(x-bsv-time)`
   - `senderIdentityKey` from `x-bsv-sender`
   - `outputIndex` from `x-bsv-vout`
5. If result `isMerge == true` → raise `VerificationError(402)` (replay)
6. On success → return `SettlementResult` with txid, network, and `x-bsv-payment-satoshis-paid` receipt header

**No PrefixStore. No challenge_secret. No nonce store.** The wallet is the entire state.

**Files:**
- `lib/x402/bsv/brc121_gateway.rb` — new
- `spec/x402/bsv/brc121_gateway_spec.rb` — new (mock wallet for unit tests)
- `spec/e2e/brc121_gateway_e2e_spec.rb` — new (real testnet, follows existing e2e pattern)

**Reuse:**
- `X402::SettlementResult` — same as other gateways
- `X402::VerificationError` — same error type
- `X402::Configuration::Route#resolve_amount_sats` — same pricing path

**Doom impact:** None. BRC121Gateway is additive.

---

### Phase 2 — Configuration: `wallet:` first-class, zero-config defaults

Make the default config story trivial:

```ruby
X402.configure do |c|
  c.wallet = my_brc100_wallet
  c.protect path: "/api/expensive", amount_sats: 100
end
```

When the user provides only `wallet:` and `protect` calls (no explicit `enable`), both `PayGateway` and `BRC121Gateway` are automatically enabled — clients can pay via either protocol.

**Changes to `lib/x402/configuration.rb`:**

1. Add `wallet:` accessor — accepts any object responding to `#internalize_action` and `#get_public_key`
2. Add `:brc121_gateway` to `GATEWAY_REGISTRY` with `BRC121_GATEWAY_KNOWN_OPTS = %i[wallet]`
3. New `build_brc121_gateway` method — wires shared `wallet:` if not overridden
4. **Auto-enable both PayGateway and BRC121Gateway** in `validate!` when:
   - `wallet:` is set
   - No `enable` calls have been made
   - No explicit `gateways=` array
5. Backwards compat: `server_wif:` keeps working — auto-builds a `WalletClient` from the WIF if `wallet:` is not set explicitly
6. `payee_locking_script_hex:` keeps working for legacy PayGateway-only configs

The two zero-config gateways have non-overlapping proof headers (`Payment-Signature` vs `x-bsv-beef`), so they coexist cleanly under the existing dispatcher — clients pick whichever protocol they support.

**Files:**
- `lib/x402/configuration.rb` — add wallet accessor, brc121 registry entry, builder, auto-enable logic
- `spec/x402/configuration_spec.rb` — new specs for wallet config and auto-enable both gateways

**Doom impact:** None. Doom uses explicit `config.enable :brc105_gateway` which still works. The auto-enable only kicks in when `enable` was never called.

---

### Phase 3 — Wallet setup/restore Rake task

`bsv-wallet` ships `BSV::Wallet::WalletClient.new(key, storage: FileStore.new)` where `key` is a `BSV::Primitives::PrivateKey` (or WIF string) and `FileStore` defaults to `~/.bsv-wallet/`. The "seed" is the WIF itself.

Provide an interactive Rake task that handles **setup or restore** without nuking existing wallets:

```bash
bundle exec rake x402:wallet:setup
```

**Behaviour:**

1. Check `~/.bsv-wallet/wallet.key` (or `BSV_WALLET_DIR/wallet.key`) — the WIF storage location
2. **If exists:** print the identity key (public), report storage dir + UTXO count, exit cleanly. **Never overwrite.** To replace: user must explicitly delete `wallet.key` or pass `FORCE=1`
3. **If absent:** prompt interactively:
   - `[1] Create new wallet` — generate random `PrivateKey`, write WIF to `wallet.key` with mode 0600
   - `[2] Restore existing wallet from WIF` — prompt for WIF (hidden input via `IO.console#noecho`), validate, write
   - `[3] Cancel`
4. After write: print confirmation with identity public key and storage dir
5. Set file mode 0600 on `wallet.key`; check parent dir is 0700 (mirroring `FileStore#check_permissions`)

**Loading the wallet at runtime:**

New helper `X402::Wallet.load` in `lib/x402/wallet.rb`:

```ruby
X402::Wallet.load                          # reads ~/.bsv-wallet/wallet.key (or BSV_WALLET_DIR)
X402::Wallet.load(dir: "/path/to/wallet")  # custom dir
```

**Key resolution order (locked decision #2):**
1. `SERVER_WIF` env var if set → use it directly
2. `BSV_WALLET_DIR/wallet.key` (or `~/.bsv-wallet/wallet.key`) if file exists → read WIF from file
3. Otherwise raise a clear error suggesting `bundle exec rake x402:wallet:setup`

Returns a fully constructed `BSV::Wallet::WalletClient` with `FileStore` pointed at the storage dir.

**Configuration integration:**

```ruby
X402.configure do |c|
  c.wallet = X402::Wallet.load
  c.protect path: "/api/expensive", amount_sats: 100
end
```

Or even shorter via convenience auto-load (Phase 2 already added `wallet:`; this phase adds the loader):

```ruby
X402.configure do |c|
  c.wallet = X402::Wallet.load   # one-line wallet boot
  c.protect ...
end
```

**Files:**
- `lib/x402/wallet.rb` — new — `X402::Wallet.load` helper
- `lib/tasks/x402.rake` — new — interactive setup task (loaded via `Rakefile`)
- `Rakefile` — load the new tasks file
- `spec/x402/wallet_spec.rb` — new — tests for `X402::Wallet.load` (uses tmpdir)
- `spec/tasks/x402_setup_spec.rb` — new — Rake task spec (mock STDIN, tmpdir)

**Reuse:**
- `BSV::Wallet::WalletClient` — already in `bsv-wallet`
- `BSV::Wallet::FileStore` — already handles `~/.bsv-wallet/` default and permissions
- `BSV::Primitives::PrivateKey.from_wif` / `#to_wif` — for WIF round-trip

**Doom impact:** None. Doom uses `SERVER_WIF` env var and constructs its own `WalletClient`. The Rake task is a new convenience for new integrators; existing env-var users keep working.

---

### Phase 4 — Documentation: position the two zero-config gateways, mark BRC-105 transitional

**Update `docs/schemes/brc-105.md`** with a transitional warning (mirror the bsv-proof.md pattern):

```markdown
!!! warning "Transitional — requires BRC-103 middleware for spec compliance"
    BRC-105 requires BRC-103 mutual authentication per §3, §5.1, §7.1. This
    implementation accepts the client identity key via `x-bsv-auth-identity-key`
    HTTP header as a transitional measure until proper BRC-103 middleware is
    implemented in Ruby (see #97 follow-up). New integrations should use either
    `PayGateway` or `BRC121Gateway` — both work zero-config and require no
    custom client instrumentation.
```

**New `docs/schemes/brc-121.md`** — full scheme doc following the bsv-pay/brc-105 template:
- Plain-English summary: "The BSV Association's simple HTTP payment protocol. Stateless server, BRC-100 wallet handles validation."
- ## Description
- ## Headers (server→client and client→server tables from spec)
- ## Process Flow (link to mermaid diagram)
- ## Replay protection — explain `isMerge` + 30s timestamp window

**New `docs/process-flow/brc121-gateway.md`** — mermaid sequence diagram

**Update `docs/index.md`** — list four schemes; explicitly call out PayGateway and BRC121Gateway as the two zero-config gateways enabled by default

**Update `docs/ecosystem.md`** — add BRC-121 to the comparison table

**Update README.md** — show the new minimal config block (`wallet:` + `protect`) as the primary example. Note that PayGateway and BRC121Gateway are auto-enabled. Show explicit `enable` examples in an "Advanced configuration" section for users who want only one gateway or who need BRC105/ProofGateway.

**Update `mkdocs.yml`** — add brc-121 to schemes nav and process flow nav

**Files:**
- `docs/schemes/brc-105.md` — add warning
- `docs/schemes/brc-121.md` — new
- `docs/process-flow/brc121-gateway.md` — new
- `docs/index.md` — update
- `docs/ecosystem.md` — update
- `README.md` — update primary example
- `mkdocs.yml` — extend nav

**Doom impact:** None. Docs only.

---

### Phase 5 — `X402::BRC103Middleware` (separate HLR, not part of this plan)

Out of scope here, but the plan acknowledges this is the unblocker for proper BRC-105 compliance. Tracked as a separate HLR. Once landed:
- BRC-103/104 handshake middleware composes upstream of `X402::Middleware`
- Sets `env['brc103.identity_key']` after successful handshake
- BRC105Gateway becomes truly spec-compliant

**Doom impact:** None in this plan. Doom can migrate at its own pace once Phase 5 ships.

---

### Phase 6 — Deprecate BRC-105 HTTP header fallback (after Phase 5)

Out of scope for this plan but the migration story is:
1. Phase 5 ships BRC-103 middleware
2. Add deprecation warning when BRC105Gateway uses the HTTP header fallback
3. One minor version later: remove the fallback
4. Coordinated with doom — they migrate to BRC-121 (simpler) or full BRC-103 stack

---

## Scope of this plan

**This plan covers Phases 1, 2, 3, and 4** (BRC121Gateway, configuration, wallet Rake task, docs). Phases 5 and 6 are acknowledged as the future direction but tracked as separate HLRs.

## Critical files

### New
- `lib/x402/bsv/brc121_gateway.rb` — Phase 1
- `lib/x402/wallet.rb` — Phase 3 (`X402::Wallet.load` helper)
- `lib/tasks/x402.rake` — Phase 3 (interactive setup task)
- `spec/x402/bsv/brc121_gateway_spec.rb` — Phase 1
- `spec/e2e/brc121_gateway_e2e_spec.rb` — Phase 1
- `spec/x402/wallet_spec.rb` — Phase 3
- `spec/tasks/x402_setup_spec.rb` — Phase 3
- `docs/schemes/brc-121.md` — Phase 4
- `docs/process-flow/brc121-gateway.md` — Phase 4

### Modified
- `lib/x402/configuration.rb` — wallet accessor, brc121 registry, auto-enable both default gateways (Phase 2)
- `lib/x402/bsv.rb` — require new gateway file (Phase 1)
- `Rakefile` — load `lib/tasks/x402.rake` (Phase 3)
- `spec/x402/configuration_spec.rb` — new wallet/auto-enable specs (Phase 2)
- `docs/schemes/brc-105.md` — transitional warning (Phase 4)
- `docs/index.md`, `docs/ecosystem.md`, `README.md`, `mkdocs.yml` — positioning (Phase 4)

### Untouched (red line)
- `lib/x402/bsv/brc105_gateway.rb` — keeps the #101 HTTP header fallback exactly as-is

## Reuse from existing code

- `X402::SettlementResult` (`lib/x402/settlement_result.rb`) — same return type for `settle!`
- `X402::VerificationError` (`lib/x402/error.rb`) — same error class with status codes
- `X402::Configuration::Route#resolve_amount_sats` — same pricing resolution
- Configuration DSL pattern from `build_pay_gateway`, `build_brc105_gateway` (`lib/x402/configuration.rb:239-295`)
- `validate_payee_source!` (`lib/x402/configuration.rb:236-241`) — already accepts wallet OR static payee
- `shared_wallet` memoisation pattern (`lib/x402/configuration.rb:78-82`) — extend to accept pre-built `wallet:` instead of always building from `server_wif`
- E2E test scaffolding from `spec/e2e/brc105_gateway_e2e_spec.rb` and `spec/e2e/e2e_helper.rb`

## Compatibility note: ProtoWallet vs WalletClient

The existing `Configuration#build_wallet` returns a `BSV::Wallet::ProtoWallet`. PayGateway and BRC105Gateway use this for BRC-42/43 derivation via `get_public_key`. `BSV::Wallet::WalletClient < ProtoWallet`, so it inherits the derivation interface and is a drop-in replacement for that purpose. BRC121Gateway needs `internalize_action`, which only `WalletClient` provides — `ProtoWallet` does not. Plan: when `wallet:` is set explicitly, use it as-is. When only `server_wif:` is set, keep building a `ProtoWallet` for backwards compat (PayGateway-only path), but additionally support `BSV::Wallet::WalletClient.new(key)` when BRC121Gateway is in the spec list (this path requires `bsv-wallet` to be loaded). The `X402::Wallet.load` helper from Phase 3 always returns a `WalletClient`, so the recommended new flow is wallet-first.

## Locked decisions

1. **Wallet key path:** `~/.bsv-wallet/wallet.key` (mode 0600), alongside the `FileStore` JSON files. `BSV_WALLET_DIR` env var override respected.
2. **WIF precedence:** `SERVER_WIF` env var wins over on-disk `wallet.key`. Doom and CI behaviour unchanged. `wallet.key` is the new default for greenfield users; env var stays the override.
3. **PR strategy:** Four sequential PRs in order — Phase 1 (BRC121Gateway) → Phase 2 (config) → Phase 3 (Rake task) → Phase 4 (docs). Each phase verifiable in isolation. Docs PR merged last so it reflects the final state.
4. **Wallet duck-typing:** Trust duck-typing for `wallet:` (consistent with gateway interface validation, not recogniser/extractor). Runtime errors will surface clearly enough.

## Verification

### Phase 1
```bash
bundle exec rake spec  # unit tests pass including new brc121_gateway_spec
bundle exec rspec spec/e2e/brc121_gateway_e2e_spec.rb  # real testnet flow
```

### Phase 2
```bash
bundle exec rake spec  # configuration_spec covers:
                       #   - wallet: accepted as config attribute
                       #   - auto-enable PayGateway + BRC121Gateway when wallet set + no enable
                       #   - explicit enable still wins
                       #   - server_wif: backwards compat path
```

### Phase 3
```bash
# Fresh setup
rm -rf /tmp/x402-wallet-test
BSV_WALLET_DIR=/tmp/x402-wallet-test bundle exec rake x402:wallet:setup
# → prompts for create/restore, writes wallet.key

# Idempotency check
BSV_WALLET_DIR=/tmp/x402-wallet-test bundle exec rake x402:wallet:setup
# → reports existing wallet, exits cleanly, NO overwrite

# Loader smoke test
ruby -r ./lib/x402/wallet -e 'p X402::Wallet.load(dir: "/tmp/x402-wallet-test").get_public_key(identity_key: true)'

bundle exec rake spec  # wallet_spec + x402_setup_spec
```

### Phase 4
```bash
bundle exec rake docs:generate    # YARD reference includes BRC121Gateway
mkdocs build --strict             # no warnings, all nav links resolve
```

### End-to-end smoke (manual, after all four phases)
1. Fresh checkout: `bundle install && bundle exec rake x402:wallet:setup` → choose create
2. Spin up minimal Sinatra app with `X402.configure { wallet: X402::Wallet.load; protect ... }` (no `enable` call)
3. Hit protected endpoint → expect 402 with **both** `Payment-Required` (PayGateway) **and** `x-bsv-sats` + `x-bsv-server` (BRC121Gateway)
4. Build BRC-121 payment via `bsv-x402` client → resubmit → expect 200 + `x-bsv-payment-satoshis-paid` receipt
5. Replay same request → expect 402 (isMerge rejection)
6. Build Coinbase v2 payment → resubmit → expect 200 + `Payment-Response` receipt (proves both gateways coexist)
