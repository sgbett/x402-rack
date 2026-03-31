# Copilot Code Review Instructions

## Project Context

x402-rack is a Ruby gem providing Rack middleware for payment-gated HTTP using BSV (Bitcoin SV) and the x402 protocol. It is **not** a wallet or funds-handling library — it is a **payment verification gateway** that sits in the HTTP request path and decides whether to serve or reject based on payment proofs.

Key architecture:
- `X402::Middleware` — pure HTTP dispatcher. No blockchain knowledge, no keys. Matches routes, polls gateways for challenges, dispatches proofs.
- `X402::BSV::PayGateway` — Coinbase v2 headers (`Payment-*`). Server broadcasts via ARC. HMAC-protected payTo, OP_RETURN request binding.
- `X402::BSV::ProofGateway` — merkleworks headers (`X402-*`). Client broadcasts, server checks mempool. Nonce UTXO provenance via 0xC3 signature verification.
- `X402::BSV::BRC105Gateway` — BSV Association headers (`x-bsv-*`). BRC-29 key derivation for unique payment addresses. AtomicBEEF transaction format. Optional BRC-103 mutual authentication.
- `X402::BSV::PrefixStore` — replay protection for BRC-105 derivation prefixes. In-memory backend with TTL and capacity limits.
- `X402::Configuration` — DSL for configuring gateways, shared dependencies (ARC client), and protected routes.
- All cryptographic operations are delegated to `bsv-sdk` and `bsv-wallet` gems — this gem does not implement crypto.

## Threat Model

**Payment bypass** is the guiding principle. Any code path that allows a client to access a protected resource without paying is critical.

Primary threats:
- **Settlement verification bypass**: accepting a proof that does not represent a valid, sufficient payment — serving content for free
- **Replay attacks**: reusing a single payment proof for multiple requests — paying once, accessing many times
- **Payment redirection**: tricking the server into accepting payment to an attacker's address instead of the configured payee
- **Challenge manipulation**: client modifying challenge data (payTo, amount, nonce) to reduce or redirect payment

Secondary threats:
- **Prefix store exhaustion**: unbounded challenge requests filling the in-memory store — denial of service via memory exhaustion
- **Information leakage**: SDK exception messages, internal paths, or configuration details exposed in HTTP error responses
- **BRC-103 identity key injection**: malicious upstream middleware injecting a crafted `env['brc103.identity_key']` to downgrade mutual-auth sessions
- **Header collision**: two gateways claiming the same proof header name — ambiguous dispatch

Non-threats (handled elsewhere):
- **Key management**: keys live in `bsv-sdk` / `bsv-wallet`, not in this gem
- **Transaction construction**: the SDK builds transactions; this gem only verifies them
- **Fee calculation**: the SDK's concern, not the middleware's
- **Network-level attacks**: TLS/HTTPS is assumed for transport security

## Review Focus Areas

### Settlement Verification (Critical — payment bypass)

- **PayGateway**: `payToSig` HMAC must be verified before trusting the client-echoed `accepted.payTo`. Constant-time comparison via `OpenSSL.fixed_length_secure_compare`. Payment output amount must be `>=` not `==` (overpayment is valid).
- **ProofGateway**: nonce UTXO must be at input index 0 (not `any?`). Profile B must verify the 0xC3 signature via full script interpreter (`verify_input(0)`). Payment output verified against the server's own payee address, not the echoed challenge.
- **BRC105Gateway**: derivation prefix must be consumed atomically, and only after full transaction validation (BEEF parsing, derivation check, payment output verification). The consume-after-validate ordering prevents MITM prefix burning.

### Replay Protection (Critical — double-spend of access)

- **PayGateway**: ARC is the replay gate — each transaction accepted once. No server-side tracking needed.
- **ProofGateway**: nonce UTXO single-spend at consensus layer. The nonce at input 0 can only be spent once.
- **BRC105Gateway**: derivation prefix consumed atomically via `PrefixStore#consume!`. The store must be thread-safe. `consume!` must return false on double-consume. TTL and capacity limits prevent unbounded growth.

### Untrusted Input Handling (High — crash/injection)

- **HTTP headers**: all proof headers (`Payment-Signature`, `X402-Proof`, `x-bsv-payment`) contain untrusted client data. JSON parsing, base64 decoding, and BEEF deserialisation must catch and wrap all exceptions.
- **Error messages**: SDK exception messages must not be forwarded to HTTP clients. Use fixed generic strings. Log server-side only.
- **AtomicBEEF parsing**: delegated to the SDK, but the catch-all `rescue StandardError` must not swallow `VerificationError` (which carries the HTTP status code).

### Configuration (Medium — misconfiguration)

- **`config.enable` DSL**: unknown option keys must raise `ConfigurationError` (not silently ignored). Conflicting convenience options (e.g. both `server_wif:` and `key_deriver:`) must raise.
- **Shared ARC client**: memoised but `arc_client` setter must take precedence over the memoised value on every call (not just first).
- **`gateways=` precedence**: if set to a non-empty array, DSL `enable` specs must be completely ignored.
- **BRC-103 identity key validation**: `env['brc103.identity_key']` must be validated as a compressed public key hex (`/\A0[23][0-9a-fA-F]{64}\z/`) before trusting it as a BRC-29 counterparty. Prevents sentinel injection (`"anyone"`).

### Header Namespace Integrity (Medium — ecosystem compatibility)

Three non-overlapping header namespaces:
- `Payment-*` — Coinbase v2 / PayGateway
- `X402-*` — merkleworks / ProofGateway
- `x-bsv-*` — BRC-105 / BRC105Gateway

Never introduce headers in another ecosystem's namespace. Duplicate proof header detection in `validate!` catches accidental collisions.

## What NOT to Flag

- **No keys in middleware**: the middleware dispatcher (`X402::Middleware`) intentionally holds no keys and signs nothing. This is by design, not an oversight.
- **`PrefixStore::Memory` is single-process only**: documented limitation. Production multi-process deployments should use a shared backend (Redis, database).
- **`OP_RETURN` binding is permissive by default in PayGateway**: allows basic clients that ignore `extra.partialTx` to still pay. Strict mode is opt-in.
- **BRC105Gateway does not inherit from Gateway**: intentional — BRC-105 uses a fundamentally different pattern (derivation-based, not template-based).
- **`x-bsv-payment-result` receipt header**: non-standard extension (BRC-105 defines no receipt header). Included for consistency with PayGateway's `Payment-Response`.
- **`wallet:` and `challenge_secret:` not surfaced as DSL convenience options**: internal gateway parameters, not user-facing configuration.
- **RuboCop `Metrics/PerceivedComplexity` disables**: on gateway builder methods in Configuration. The complexity is inherent to option expansion logic.

## Style

- Be specific: cite file paths and line numbers.
- Lead with **payment bypass impact**, not description. "This allows unpaid access because..." not "This doesn't follow best practice because..."
- Provide fix recommendations with code, not just problem statements.
- Skip cosmetic issues, style preferences, and general best practices unless they have a payment-bypass or denial-of-service implication.
- Focus on the diff, not the entire codebase. Pre-existing patterns are not new findings.
