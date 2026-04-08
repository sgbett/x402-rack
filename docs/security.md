# Security

## Threat Model

The x402 middleware gates access to HTTP resources based on payment. The primary threats are:

1. **Payment bypass**: accessing protected content without paying
2. **Payment redirection**: tricking the server into accepting payment to an attacker's address
3. **Replay attacks**: reusing a single payment for multiple requests
4. **Nonce forgery**: crafting a fake challenge that passes verification

## PayGateway Security

### payToSig HMAC

The `payTo` field in the challenge is HMAC-signed with a server-side secret (`challenge_secret`, auto-generated per gateway instance). At settlement, the HMAC is verified before trusting the client-echoed `accepted.payTo`.

**Attack prevented**: client substitutes their own `payTo` address in the `accepted` block, constructs a transaction paying themselves, and submits it as proof. The HMAC mismatch rejects the attempt.

- Uses `OpenSSL::HMAC.hexdigest("SHA256", secret, payTo)`
- Constant-time comparison via `OpenSSL.fixed_length_secure_compare`
- Nil signature detection (missing `payToSig` is rejected)

### OP_RETURN Request Binding

The payment is bound to the specific HTTP request via `SHA256(method + path + query)` in an OP_RETURN output. Prevents a template generated for one endpoint from being submitted to a different endpoint.

- **Strict mode**: rejects transactions without the matching OP_RETURN
- **Permissive mode** (default): accepts transactions without OP_RETURN (for basic clients that ignore `extra.partialTx`)

### ARC as Replay Gate

Each transaction can only be broadcast once. ARC rejects double-spends at the network layer. No server-side replay tracking needed.

## ProofGateway Security

### Challenge Cache (Provenance Gate)

Settlement recovers the original, server-issued challenge from an
in-memory TTL-bounded `ChallengeStore` keyed by `challenge_sha256`, not
from a client-echoed `X402-Challenge` header. The merkleworks spec only
mandates that clients echo `challenge_sha256` in the proof — the server
is responsible for recovering the challenge itself.

This closes the forged-challenge provenance hole: an attacker cannot
populate the server's store, so a proof referencing a challenge that was
never issued by this server misses the cache and is rejected with
`challenge not found or expired` (400) before any downstream check runs.

The entry is `consume!`d after a successful settlement, so the same
proof cannot be replayed against the same server. Combined with
Bitcoin's UTXO single-spend guarantee at the network layer, this gives
both in-window and long-term replay protection.

**Per-instance, in-memory**: the default `ChallengeStore::Memory` backend
is per-process. Multi-worker deployments (e.g. Puma pre-fork) will need
a shared backend before production use.

Mirrors the merkleworks reference implementation's mandatory
`ChallengeCache` — their `docs/AUDIT.md` frames "stateless" as "the
replay cache is not a correctness gate" while relying on a separate
challenge cache for provenance. Same pattern applied here.

### Nonce Provenance (Profile B)

The `0xC3` signature on input 0 proves the server issued the nonce. At settlement:

1. Input 0 must be the nonce UTXO (enforced by index, not `any?`)
2. Full P2PKH script verification via `transaction.verify_input(0)` — validates signature, pubkey, and sighash
3. Source UTXO details (satoshis, locking script) are sourced from the **cached** challenge, not the client-echoed header — so an attacker cannot substitute their own nonce script to satisfy the provenance check

**Attack prevented**: attacker crafts a fake unlocking script containing the server's public key bytes but with an invalid signature. The full script interpreter catches this — `OP_CHECKSIG` fails.

**Attack prevented**: attacker places the nonce at input 1 and a fake input at index 0. The index-0 enforcement in `check_nonce_input!` rejects this.

### Nonce Key Validation

Key validation is the treasury's responsibility. The gateway never holds a private key — the `nonce_provider` callable builds and signs the template. Misconfiguration (key/UTXO mismatch) is caught at settlement time when `verify_input(0)` fails.

### Payee Verification

Payment output is verified against the server's own payee address (`resolve_static_payee_hex`), not the echoed challenge's payee. The echoed challenge is client-supplied and cannot be trusted for payee verification.

## BRC105Gateway Security

### BRC-29 Key Derivation

Payment addresses are derived using BRC-42 with protocol ID `[2, "3241645161d8"]` and key ID `"#{prefix} #{suffix}"`. The server re-derives the expected P2PKH script at settlement — a client cannot redirect payment without knowing the server's private key.

**No payTo HMAC needed** — the payment address is cryptographically bound to the server's identity key. Unlike PayGateway (where the client echoes a `payTo` address), BRC-105 clients derive the address themselves.

### Prefix Store Replay Protection

Each challenge issues a unique derivation prefix. The prefix is consumed atomically at settlement — after full transaction validation, before broadcast. This ordering prevents a MITM from burning a legitimate client's prefix by submitting garbage first.

**Bounded store**: The in-memory store enforces a TTL (default 300s) and max capacity (default 10,000) to prevent heap exhaustion from unauthenticated challenge requests.

### BRC-103 Identity Key Validation

When `env['brc103.identity_key']` is present, the gateway validates it as a compressed public key hex (`/\A0[23][0-9a-fA-F]{64}\z/`) before trusting it as the BRC-29 derivation counterparty. This prevents a compromised upstream middleware from injecting the sentinel string `"anyone"` to silently downgrade mutual-auth sessions.

### AtomicBEEF Parsing

Transactions arrive as base64-encoded AtomicBEEF (BRC-95). Parsing is delegated to the SDK. Error messages from SDK internals are not forwarded to HTTP clients — fixed generic strings are returned instead to prevent information leakage.

### No OP_RETURN Binding

BRC-105 does not use OP_RETURN request binding. The payment is bound to the specific challenge via the derivation prefix (unique per request). The prefix-to-request mapping is server-side state.

## Common Security Properties

### No Keys in Middleware

The gatekeeper (`X402::Middleware`) holds no keys and signs nothing. It is a pure dispatcher. All cryptographic operations happen in the gateways.

### Wallet as Security Boundary

The `bsv-wallet` gem (BRC-100 interface) is the security boundary. Gateways talk to it exclusively through the BRC-100 API. Keys never leave the wallet.

### Error Handling

- `VerificationError` with specific status codes (400, 402, 502) for expected failures
- `StandardError` catch-all returns generic 500 with fixed message (no internal details leaked)
