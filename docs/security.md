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

### Nonce Provenance (Profile B)

The `0xC3` signature on input 0 proves the server issued the nonce. At settlement:

1. Input 0 must be the nonce UTXO (enforced by index, not `any?`)
2. Full P2PKH script verification via `transaction.verify_input(0)` — validates signature, pubkey, and sighash
3. Source UTXO details (satoshis, locking script) set from the challenge before verification (BIP-143 requirement)

**Attack prevented**: attacker crafts a fake unlocking script containing the server's public key bytes but with an invalid signature. The full script interpreter catches this — `OP_CHECKSIG` fails.

**Attack prevented**: attacker places the nonce at input 1 and a fake input at index 0. The index-0 enforcement in `check_nonce_input!` rejects this.

### Nonce Key Validation

At challenge time (template signing), the gateway validates that the nonce key's public key hash matches the nonce UTXO's P2PKH locking script. Catches misconfiguration before producing an invalid template.

### Payee Verification

Payment output is verified against the server's own payee address (`resolve_static_payee_hex`), not the echoed challenge's payee. The echoed challenge is client-supplied and cannot be trusted for payee verification.

## Common Security Properties

### No Keys in Middleware

The gatekeeper (`X402::Middleware`) holds no keys and signs nothing. It is a pure dispatcher. All cryptographic operations happen in the gateways.

### Wallet as Security Boundary

The `bsv-wallet` gem (BRC-100 interface) is the security boundary. Gateways talk to it exclusively through the BRC-100 API. Keys never leave the wallet.

### Error Handling

- `VerificationError` with specific status codes (400, 402, 502) for expected failures
- `StandardError` catch-all returns generic 500 (implementation detail: currently leaks `e.message` — should be made generic in production)
