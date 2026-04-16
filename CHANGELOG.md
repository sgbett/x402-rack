# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.11.0] - 2026-04-16

### Changed — Breaking

- **Vendor broadcasts: the NO PAY → NO CONTENT enforcement now uses server-side broadcast, not client-broadcast verification.** `BRC121Gateway` and `BRC105Gateway` broadcast the client's signed BEEF to ARC themselves (idempotent — safe if the client already broadcast). This matches BSV's native commerce model: the vendor settles the payment. The previous status-check approach (0.10.2) is replaced.
- `config.verify_on_chain` accessor removed. The `X402_VERIFY_ON_CHAIN` env var is no longer honoured. Vendor-broadcast is not optional — there is no meaningful "partial enforcement" mode. If you need to disable payments for dev or staging, mock the gateway or don't enable payment middleware on the routes you want un-gated.
- `network_visibility_cache:` kwarg removed from `BRC121Gateway` and `BRC105Gateway` constructors.

### Removed

- `X402::BSV::NetworkVisibility` module (helper, cache, retry loop) — entire file deleted. Replaced by direct `arc.broadcast(subject_tx, wait_for:)` calls on the gateway.

### Added

- `arc_client` is now required (not optional) for `BRC121Gateway` and `BRC105Gateway` at settle time. A missing `arc_client` raises `VerificationError(500)` "payment broadcaster not configured" — the invariant cannot be enforced without it.

### Why this pivot

The status-check approach shipped in 0.10.2 worked but was architecturally wrong. BSV commerce model: the vendor is the settlement point. ARC is idempotent — broadcasting the same tx twice is a no-op, not duplicated work. By broadcasting ourselves, we guarantee the tx is on-chain before returning 200, with no propagation race, no `no_send` exploit surface, and simpler code.

### Gemspec

- `bsv-sdk` floor raised to `>= 0.12.0` (no new method added; existing `arc.broadcast` is the mechanism).

## [0.10.2] - 2026-04-16

### Fixed

- **NO PAY → NO CONTENT invariant is now enforced at the gateway layer.** `BRC121Gateway` and `BRC105Gateway` verify on-chain visibility via ARC before `internalize_action`, closing the `no_send` exploit window left open by 0.10.0 / 0.10.1. A structurally valid BEEF that was never broadcast now receives `402 Payment Required` ("payment transaction not visible on the BSV network") instead of a 200 with content served. Closes #148; completes #158.
- `BRC121Gateway#server_identity_key` now calls `@wallet.get_public_key({ identity_key: true })` with a positional hash rather than kwargs, matching `BSV::Wallet::WalletClient`'s `(args, originator:)` signature. Ruby 3.4 strict hash/kwargs separation rejected the previous kwargs form on any real `WalletClient` — BRC-121 challenges would fail in production even though unit tests passed against mock doubles.

### Added

- `X402::BSV::NetworkVisibility` — shared helper centralising the "is this txid visible on the BSV network via ARC?" check. Bounded retries (4 attempts, ~1.75 s worst case), positive-only TTL cache (~30 s), and clean fault classification: non-visible statuses surface as 402, ARC 5xx / `SocketError` / `Timeout::Error` as 503. Used by `BRC121Gateway`, `BRC105Gateway`, and `ProofGateway` (#161).
- On-chain visibility verification in `BRC121Gateway` via a new `arc_client:` constructor kwarg. Runs between payment-output verification and `wallet.internalize_action` so wallet state is never mutated for an unbroadcast tx (#162).
- On-chain visibility verification in `BRC105Gateway` via a new `arc_client:` constructor kwarg. Runs between payment-output verification and `consume_prefix!` — verify-before-consume ordering is deliberate so a legitimate retry after re-broadcast can still use the same prefix (#163).
- `config.verify_on_chain` (default `true`) and `X402_VERIFY_ON_CHAIN` env var — dev/staging kill-switch that skips the ARC visibility check when wallets may be mocked or never broadcast. Logs a loud WARN at startup when disabled: `verify_on_chain is disabled — NO PAY → NO CONTENT is NOT enforced. Do not run in production.` (#164)
- Configuration auto-injects `shared_arc_client` into `BRC121Gateway` and `BRC105Gateway` so zero-config users get the invariant for free (#164).

### Changed

- `ProofGateway#check_mempool!` now delegates to `X402::BSV::NetworkVisibility.verify!`, sharing the retry policy, positive-only TTL cache, and fault classification with BRC-121 / BRC-105 gateways. The 8-value `ACCEPTABLE_MEMPOOL_STATUSES` whitelist is preserved verbatim and passed as `visible_statuses:` — ProofGateway's "is my broadcast propagating?" semantics are unchanged (#165).
- **Breaking (status code):** ARC outages observed by `ProofGateway` now surface as `VerificationError(status: 503)` where previously they surfaced as `502`. This aligns the operator-facing status across all gateways: every ARC outage is a 503 regardless of which gateway was in the path. Callers that explicitly branched on `status == 502` must update to `503`.

### Removed

- `ProofGateway::MEMPOOL_RETRY_DELAYS_SECONDS` constant — retry timing is now owned by `X402::BSV::NetworkVisibility::RETRY_DELAYS_SECONDS`.

### Operator notes

- **ARC reachability is now a hard runtime dependency** on the critical path for BRC-121 and BRC-105 settlement (it was already one for PayGateway and ProofGateway). Monitor ARC 5xx rate and latency the same way you monitor your own database. The 402-vs-503 split is designed to drive different alert paths: elevated 402s mean client misbehaviour or exploit attempts; elevated 503s mean an ARC incident.

## [0.10.1] - 2026-04-16

### Removed

- Gateway-level ARC broadcast added in 0.10.0 — broadcast is the wallet's responsibility via the `broadcaster:` parameter on `WalletClient`, not the gateway's. By the time the BEEF arrives at the gateway, the client's wallet should have already broadcast. If the client used `no_send: true` without broadcasting, the correct response is to reject (optionally via an `arc_client.status(txid)` read), not to paper over client misconfiguration by re-broadcasting on their behalf (#155)
- `broadcast_to_arc!` method from BRC105Gateway and BRC121Gateway
- `arc_client:` constructor parameter from BRC105Gateway and BRC121Gateway
- Configuration auto-injection of `arc_client` into BRC105Gateway and BRC121Gateway

### Fixed

- 0.10.0 depended on an unreleased `broadcast_beef` method on `BSV::Network::ARC`, making all BRC-121 and BRC-105 settlements fail with `NoMethodError` against any released `bsv-sdk`

## [0.10.0] - 2026-04-16

### Added

- BRC105Gateway and BRC121Gateway now broadcast payment BEEF to ARC before internalisation, enforcing the "no credit without on-chain settlement" invariant (#148)
- Configuration auto-injects `shared_arc_client` into BRC105Gateway and BRC121Gateway (same pattern as PayGateway)
- ARC broadcast is idempotent — both client and server can broadcast the same tx safely

### Changed

- Status endpoint resolves identity via `shared_wallet.get_public_key` instead of parsing `server_wif` directly — works with local wallets, remote wallets, and WIF-backed proto-wallets (#143)
- Status endpoint error messages are now wallet-agnostic

### Dependencies

- Requires `bsv-sdk` with `broadcast_beef` support (sgbett/bsv-ruby-sdk@88799c0)
- Bump rake 13.3.1 → 13.4.1, yard 0.9.39 → 0.9.40

## [0.9.1] - 2026-04-13

### Fixed

- Replace deprecated TAAL ARC endpoints with ARCADE (`arcade.gorillapool.io`, `testnet.arcade.gorillapool.io`) across all e2e specs, docs, and configuration examples (#139)

## [0.9.0] - 2026-04-13

### Added

- Node.js wallet server fixture and RemoteWallet adapter for e2e testing
- Relay-mode config.ru for e2e PayGateway tests

### Fixed

- Accept BEEF (BRC-62) from client for wallet internalisation — BRC-100 wallets require BEEF, not raw tx bytes (#134)
- Call `internalize_action` with positional Hash matching ProtoWallet convention (#137)
- `RemoteWallet#get_public_key` calling convention mismatch with ProtoWallet interface
- BRC-100 wallet compatibility for PayGateway relay (base64 derivation params, identity key)
- Scope rescue in teardown to prevent health check spin

### Changed

- Bump bsv-sdk 0.11.0, bsv-wallet 0.7.0

## [0.8.0] - 2026-04-12

### Added

- **RemoteWallet adapter** (`X402::RemoteWallet`) — HTTP client implementing
  the duck-typed wallet interface by calling a remote `@bsv/simple` server
  wallet API. Supports `get_public_key` (with identity key caching) and
  `internalize_action` for settlement relay. Thread-safe.
- **BRC121Gateway** — new gateway implementing the BRC-121 "Simple 402
  Payments" spec. Stateless server with BRC-100 wallet-backed validation
  via `internalize_action`. 30-second timestamp freshness window, TxidStore
  replay protection, and `isMerge` checking for wallet-level deduplication.
- **`operator_wallet_url` configuration** — point at an existing `@bsv/simple`
  server wallet and PayGateway is auto-enabled with no keys on the server.
  The minimal three-line configuration path.
- **`config.wallet =` DSL** — first-class wallet attribute. When set with no
  explicit `enable` calls, both PayGateway and BRC121Gateway are auto-enabled.
- **`config.network =` attribute** — parameterised BSV network (`bsv:mainnet`
  or `bsv:testnet`). Respects `BSV_NETWORK` environment variable. Replaces
  hardcoded `NETWORK` constants across all four gateways.
- **ARC default fallback** — `build_arc_client` falls back to `ARC.default`
  (GorillaPool Arcade) when no explicit `arc_url` is configured.
- **PayGateway wallet relay** — after ARC broadcast, relays settlement to the
  operator's wallet via `internalize_action` (log-and-continue on failure).
  BRC-29 derivation params round-trip through the challenge for wallet-
  spendable addresses.
- **`X402::Wallet.load`** — resolves signing WIF from `SERVER_WIF` env or
  `~/.bsv-wallet/wallet.key`, returns a fully-constructed `WalletClient`.
- **`rake x402:wallet:setup`** — interactive wallet create/restore task.
  Never overwrites existing wallets. File permissions enforced (0600/0700).
- **Rails Railtie** — auto-loads rake tasks in Rails applications.

### Changed

- **BRC105Gateway: `wallet:` replaces `arc_client:`** — `settle!` now uses
  `wallet.internalize_action` instead of direct ARC broadcast, per the
  BRC-105 spec. Constructor takes `wallet:` parameter; `arc_client:` removed.
  **(Breaking for direct BRC105Gateway construction; DSL users update
  seamlessly.)**
- **Gateway base class uses BRC-29 protocol ID** — `[2, "3241645161d8"]`
  replaces `[2, "x402 payment"]`. Derived addresses are now wallet-spendable
  via standard BRC-29 key derivation.
- **PayGateway challenge carries `derivationPrefix`/`derivationSuffix`**
  instead of `keyId`. HMAC covers payTo + prefix + suffix.
- **Gemspec dependency floors raised** — `bsv-sdk >= 0.9.0`, `bsv-wallet >= 0.5.0`.

### Fixed

- **PayGateway BRC-29 derivation alignment** — was using a custom protocol ID
  that no wallet recognised; operator funds were unrecoverable. Now uses the
  standard BRC-29 protocol ID shared with BRC-105 and BRC-121.
- **ProofGateway lenient base64** — `Base64.decode64` replaced with
  `strict_decode64`, consistent with all other gateways.
- **PayGateway `verify_binding!`** — now uses `build_op_return_script` instead
  of duplicating the OP_RETURN hex via string interpolation.
- **BRC121Gateway nonce validation** — two-layer check (regex + `strict_decode64`).
- **BRC121Gateway `check_internalization_result!`** — checks `isMerge` and
  `accepted` on the wallet result per BRC-121 §5 step 5.
- **Wallet setup file permissions** — `File.chmod` enforced after write on
  both new and pre-existing files/directories.

## [0.7.0] - 2026-04-08

### Added

- **ProofGateway challenge cache** — new `X402::BSV::ChallengeStore::Memory`,
  a per-process TTL-bounded store of issued challenges keyed by their
  canonical sha256. `ProofGateway` records each challenge at issuance and
  looks it up at settlement instead of trusting a client-echoed
  `X402-Challenge` header. Closes the forged-challenge provenance hole
  (#23) and kills same-proof replay (the entry is consumed on successful
  settlement). Matches the merkleworks reference implementation's
  mandatory `ChallengeCache` pattern without otherwise aligning with
  their architecture.

### Changed

- **ProofGateway no longer consults the echoed `X402-Challenge` header at
  settlement.** The merkleworks spec only mandates that clients echo
  `challenge_sha256` in the proof; the server recovers the original
  challenge from its own store. Proofs referencing a challenge that was
  never issued by this server (or has been consumed / expired) are now
  rejected with `challenge not found or expired` (400).
- **ProofGateway documentation softened** — the "experimental, do not use
  in production" warning on the BSV-proof scheme doc has been replaced
  with an "under development" note reflecting the closed provenance
  hole and the per-instance cache limitation.
- **ProofGateway mempool check is now propagation-tolerant.**
  `check_mempool!` retries ARC status (4 attempts, ~1.75s total
  worst case) to absorb the window between broadcast and
  `SEEN_ON_NETWORK`. The acceptable-status whitelist has been
  broadened to include every non-error ARC state (`RECEIVED`,
  `STORED`, `ANNOUNCED_TO_NETWORK`, `REQUESTED_BY_NETWORK`,
  `SENT_TO_NETWORK`, `ACCEPTED_BY_NETWORK`, `SEEN_ON_NETWORK`,
  `MINED`). Matches the merkleworks reference implementation's
  `visible` check — Bitcoin's single-spend at the network layer
  remains the actual replay gate. Error message now surfaces the
  last observed status to aid ops debugging.

### Fixed

- **ProofGateway concurrent-settlement race.** `consume_challenge!`
  previously ignored the return value of the store's atomic
  `consume!`, allowing two threads racing the same proof to both
  return a `SettlementResult`. Losers of the race now raise
  `challenge not found or expired` (400), so exactly one settlement
  succeeds per issued challenge even under concurrency.
- **Middleware now preserves the gateway's status when challenge
  issuance fails.** `X402::Middleware#issue_challenge` gained a
  `VerificationError` rescue matching `settle_and_forward`, so a 503
  from a saturated `ChallengeStore` reaches the client as 503 instead
  of bubbling to a generic 500.

## [0.6.0] - 2026-04-05

### Added

- **Configurable structured logging** — pluggable `logger` on configuration with structured request lifecycle messages (route match, identity key, proof dispatch, settlement outcome). (#102)
- **BRC-105 settlement logging** — structured log output for derivation, key ID, locking script verification, and settlement result in `BRC105Gateway`. (#96)
- **BRC-105 §6.2 response body** — settlement success and error responses now include spec-conformant JSON body with receipt details. Spec-anchored tests. (#91)
- **BRC-105 response headers** — `x-bsv-payment-version` and `x-bsv-payment-satoshis-paid` headers on successful settlement. (#91)
- **API documentation** — YARD-style docs for public interfaces. (#89)

### Changed

- **Client identity key required for BRC-105** — `x-bsv-auth-identity-key` header is now mandatory for BRC-105 settlement (§7.1). Requests without it receive a 401 error. (#99)

### Fixed

- **ARC broadcast error details** — error messages from ARC are now logged and surfaced in the 502 response rather than swallowed silently.
- **Base64 `derivationSuffix` accepted** — client-generated suffixes may be base64-encoded (not just hex). Validation updated to accept both formats. (#93)

### Build

- **Dependency updates** — bsv-sdk 0.6.0 → 0.6.1, rack 3.2.6.

## [0.5.1] - 2026-04-04

### Fixed

- **PaymentObserver now protocol-agnostic** — `extract_and_validate` no longer hardcodes the Coinbase v2 envelope format. Pluggable `extractor:` parameter (duck-typed `#call(proof_payload)` → `Transaction` or `nil`) enables BRC-105 and custom payment formats. Default `CoinbaseV2Extractor` preserves backwards compatibility. (#84)

## [0.5.0] - 2026-04-04

### Changed

- **Default `binding_mode` now `:strict`** — OP_RETURN request binding enforced by default. Set `binding_mode: :permissive` to restore previous behaviour.

### Added

- **Txid deduplication store** — `record_if_unseen!` prevents double-processing of the same transaction across settlement and observer paths.

### Fixed

- **Security audit quick wins** — handle numeric JSON amount, non-string derivation components (H-3, M-2, M-4, M-5).
- **SettlementWorker hardening** — `on_failure` callback, capped queue via Queue with size check (replaces SizedQueue), exponential backoff improvements.
- **Atomic txid deduplication** — `record_if_unseen!` provides thread-safe check-and-insert in a single call.
- **Runtime warnings scoped** — warnings emitted only for relevant gateways, check value not just key presence.
- **Production environment warnings** — warn on ephemeral `challenge_secret` and in-memory `PrefixStore`.

## [0.4.0] - 2026-04-03

### Added

- **Server wallet** — `config.server_wif` builds a shared `ProtoWallet` (BRC-42/43 key derivation) for all gateways. Per-payment derived addresses, no address reuse. Falls back to static `payee_locking_script_hex` when not set. Per-gateway overrides (`wallet:`, `key_deriver:`) take precedence.
- **Settlement worker** — `X402::SettlementWorker` for async background broadcast. Ruby stdlib only (Thread + Queue), exponential backoff retry, zero dependencies. Pluggable interface (`#enqueue(tx_binary)`) for Sidekiq/Redis.
- **Per-route ARC thresholds** — `config.protect` accepts `arc_wait_for:` to override the gateway default. `:async` validates tx locally then enqueues, responding 200 immediately.
- **Payment observer** — `X402::PaymentObserver` Rack middleware for voluntary ungated payments. Watches for payment headers, validates payee, enqueues to settlement worker. Never gates access. Configurable proof headers and `on_payment` callback.
- **Pluggable recogniser** — `PaymentObserver` accepts `recogniser:` (any object responding to `#ours?(locking_script_hex)`) for BRC-29 derived address payment channels. `StaticRecogniser` wraps the existing static payee behaviour.
- **Fiat-denominated pricing** — `config.protect` accepts `amount_usd:` resolved to sats at challenge time via `exchange_rate_provider`. Also accepts callable `amount_sats:` for any dynamic pricing. Provider interface: `#sats_for(currency, amount)`.

### Changed

- **`build_template` signature** — now accepts `required_sats` integer instead of route object. Gateways snapshot the resolved amount once per request.
- **ProofGateway rejects callable pricing** — raises `ConfigurationError` at challenge time. The merkleworks canonical hash includes `amount_sats`; a callable would produce different hashes across requests.

### Fixed

- **`arc_wait_for` coerced to string** — prevents Symbol values being passed to ARC client.
- **PaymentObserver pass-through guarantee** — enqueue/callback failures wrapped in rescue, never break the request.
- **Recogniser interface validated** — `ConfigurationError` if recogniser doesn't respond to `#ours?`.
- **Static payee hex canonicalised** — round-trips through `Script.from_hex.to_hex` in `StaticRecogniser`.
- **Exchange rate provider validated** — `ConfigurationError` if provider doesn't respond to `#sats_for`.

## [0.3.0] - 2026-04-02

### Added

- **Configuration DSL** — `config.enable :pay_gateway` with shared dependencies (ARC client, payee script) wired automatically. Convenience options: `server_wif:` builds KeyDeriver, `nonce_wif:` builds PrivateKey, default PrefixStore for BRC-105. Per-gateway overrides supported. Deferred construction at `validate!` time. Full backwards compatibility with `config.gateways = [...]`.
- **Copilot review instructions** — `.github/copilot-instructions.md` with payment-bypass-focused review guidance.
- **Dependabot** — weekly checks for bundler and GitHub Actions dependencies.

### Changed

- **Treasury refactor** — ProofGateway no longer holds the treasury's private key (`nonce_key:` removed). The `nonce_provider` callable now optionally returns a pre-signed `partial_tx:` for Profile B. Signing responsibility pushed from gateway to treasury. Trust boundary: `[(X)+(B)] <-> [(T)]`.
- **nonce_provider interface** — now receives `payee:` and `amount:` kwargs. Profile detection moved from constructor config to provider response.
- **Dependencies** — `bsv-sdk ~> 0.4`, `bsv-wallet ~> 0.2` (BRC-100 wallet interface now available).

### Fixed

- **ARC wait_for enforced** — PayGateway now passes `arc_wait_for` to `broadcast(tx, wait_for:)`. Previously stored but never used.
- **Mempool status validated** — ProofGateway `check_mempool!` now verifies `tx_status` is `SEEN_ON_NETWORK`, `ANNOUNCED_TO_NETWORK`, or `MINED`. Non-propagated statuses (`RECEIVED`, `STORED`) correctly rejected.
- **Error messages hardened** — all gateways, middleware, and protocol parsers now return fixed generic strings. No SDK exception messages forwarded to HTTP clients.
- **Config DSL memoisation** — `shared_arc_client` checks injected `arc_client` on every call, not just first.

### Removed

- **`nonce_key:` parameter** from ProofGateway constructor (breaking change for Profile B users — signing moves to nonce_provider).
- **`nonce_wif:` and `nonce_key:` convenience options** from configuration DSL (no longer applicable).

## [0.2.0] - 2026-03-30

### Added

- **BRC-105 Gateway** — `X402::BSV::BRC105Gateway` implementing the BSV Association's native payment protocol (`x-bsv-*` headers). Uses BRC-29 key derivation for unique per-payment addresses and AtomicBEEF (BRC-95) transaction format.
- **Prefix Store** — `X402::BSV::PrefixStore::Memory` for BRC-105 derivation prefix replay protection. Thread-safe via Monitor, with TTL-based expiry (default 300s) and max capacity cap (default 10,000).
- **BRC-103 composition** — BRC105Gateway works standalone (advertises server identity key in header) or composes with future BRC-103 mutual authentication middleware. Detects mode automatically from `env['brc103.identity_key']`.
- **BRC-105 e2e test** — full standalone payment flow against BSV testnet (derive address, build tx, encode AtomicBEEF, verify, broadcast).
- **Comprehensive documentation** — scheme doc (`docs/schemes/brc-105.md`), process flow diagrams for both standalone and authenticated modes, security analysis, client integration guide.

### Security

- Derivation prefix consumed after full transaction validation, not before (prevents MITM prefix burning).
- BRC-103 identity key validated as compressed pubkey hex before trusting as BRC-29 counterparty (prevents sentinel injection).
- SDK exception messages not forwarded to HTTP clients — fixed generic strings returned.
- `PrefixStore::Memory` bounded with TTL and max capacity to prevent heap exhaustion from unauthenticated challenge requests.
- `StoreFullError` returns 503 (server at capacity), not 400.

## [0.1.0] - 2026-03-28

### Added

#### Middleware

- **`X402::Middleware`** — pure Rack dispatcher for payment-gated HTTP. No blockchain knowledge, no keys. Matches routes, polls gateways for challenge headers, dispatches proofs to the matching gateway.
- **Multi-gateway support** — multiple gateways can be configured simultaneously. The middleware issues challenge headers from all gateways and dispatches proofs to whichever gateway recognises the proof header.
- **Payment content negotiation** — different x402 ecosystems use different HTTP headers. A server sends multiple challenge headers; the client picks the one it can satisfy.

#### Gateways

- **`X402::BSV::PayGateway`** — Coinbase v2 headers (`Payment-Required` / `Payment-Signature` / `Payment-Response`). Server broadcasts via ARC. HMAC-signed `payToSig` prevents payee address tampering. OP_RETURN request binding (strict/permissive mode). This is the recommended "BSV way" — vendor verifies, vendor broadcasts, vendor serves.
- **`X402::BSV::ProofGateway`** — merkleworks x402 headers (`X402-Challenge` / `X402-Proof`). Client broadcasts, server checks mempool. Profile A (bare nonce metadata) and Profile B (pre-signed template with 0xC3 nonce signature for provenance).
- **`X402::BSV::Gateway`** — base class for template-based gateways. Builds partial transaction templates with payment output and OP_RETURN binding. Supports wallet-based address derivation (BRC-43) or static payee address.

#### Configuration

- **Route protection** — `config.protect method: :GET, path: "/api/expensive", amount_sats: 100`
- **Duplicate proof header detection** — validates no two gateways claim the same proof header name.

#### Testing

- **E2e test suite** — PayGateway, ProofGateway (Profile B), and fee delegation flows tested against BSV testnet with real ARC broadcasts.
- **E2ELogger** — pretty logging with actors, timestamps, transaction links, and timestamped markdown log files.
- **Fee delegation e2e** — treasury + client + delegator + payee four-wallet flow with 0xC3 sighash alignment.

#### Documentation

- **Architecture docs** — middleware as dispatcher, gateway interface, component boundaries, unified template model, 0xC3 sighash rationale.
- **Scheme docs** — BSV-pay and BSV-proof with headers, challenge/settlement flows, replay protection.
- **Process flow diagrams** — mermaid sequence diagrams for PayGateway and ProofGateway.
- **Security docs** — threat model, payToSig HMAC, nonce provenance (Profile B), OP_RETURN binding, error handling.
- **Operations docs** — deployment, performance, treasury/nonce lifecycle.
- **Ecosystem docs** — Coinbase v2, merkleworks, BRC-105 positioning and header namespace reservations.

[0.5.1]: https://github.com/sgbett/x402-rack/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/sgbett/x402-rack/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/sgbett/x402-rack/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/sgbett/x402-rack/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/sgbett/x402-rack/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/sgbett/x402-rack/releases/tag/v0.1.0
