# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
