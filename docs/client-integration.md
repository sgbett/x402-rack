# Client Integration

## bsv-x402 (JavaScript/TypeScript)

The client library wraps `fetch()` and handles the x402 payment flow transparently:

```js
import { x402Fetch } from 'bsv-x402'

const response = await x402Fetch('https://api.example.com/paid-endpoint')
```

When the server responds with `402 Payment Required`, the library:

1. Parses the challenge header (`Payment-Required` or `X402-Challenge`)
2. Constructs a payment transaction via `window.CWI` (BRC-100 wallet)
3. Extends the `extra.partialTx` template if present (or builds from scratch)
4. Broadcasts the transaction (ProofGateway) or hands it to the server (PayGateway)
5. Retries the original request with the proof header

The app developer just uses `x402Fetch` in place of `fetch`. The UI doesn't flicker — the data just arrives.

**Repository**: [sgbett/bsv-x402](https://github.com/sgbett/bsv-x402)
**npm**: `bsv-x402`

## BRC-100 and `window.CWI`

[BRC-100](https://github.com/bitcoin-sv/BRCs/blob/master/wallet/0100.md) is a vendor-neutral wallet-to-application interface. Compliant wallets inject a `window.CWI` object into web pages — analogous to `window.ethereum` in the Ethereum ecosystem.

Key methods used by the x402 client:
- `createAction()` — construct and sign transactions
- `signAction()` — sign previously created transactions
- `listOutputs()` — find available UTXOs for funding

Because this uses BRC-100 (not a browser-specific API), it works with any compliant wallet.

## BSV Browser

[BSV Browser](https://github.com/bsv-blockchain/bsv-browser) is the reference BRC-100 wallet implementation. It exposes `window.CWI` and is the primary target for testing the end-to-end flow.

The planned integration path:
1. User visits a site protected by x402-rack
2. BSV Browser's `window.CWI` is available
3. `bsv-x402` intercepts the 402 and calls `CWI.createAction()`
4. Payment happens seamlessly — the user sees the content load

## Client Behaviour by Scheme

### BRC105Gateway (BRC-105)

1. Client receives `x-bsv-payment-satoshis-required`, `x-bsv-payment-derivation-prefix`, and `x-bsv-payment-identity-key` headers
2. Client chooses a random derivation suffix
3. Derives payment address using BRC-29: `KeyDeriver.derive_public_key([2, "3241645161d8"], "#{prefix} #{suffix}", server_identity_key)`
4. Builds a transaction paying to the derived P2PKH address
5. Encodes the transaction as AtomicBEEF (BRC-95), base64
6. Sends `x-bsv-payment` header with JSON: `{ "derivationPrefix": "...", "derivationSuffix": "...", "transaction": "<base64 AtomicBEEF>" }`
7. Server verifies derivation, broadcasts via ARC, returns `x-bsv-payment-result`

**BRC-103 authenticated mode**: the client already has the server's identity key from the BRC-103 handshake — the `x-bsv-payment-identity-key` header is omitted. The client's authenticated identity key is used as the BRC-29 counterparty, binding the payment to the mutual-auth session.

**BRC-100 wallet integration**: BRC-105 clients can use `wallet.createAction()` to build the transaction and `wallet.internalizeAction()` on the server to process it. The derivation prefix/suffix flow integrates natively with BRC-100's payment handling.

### PayGateway (BSV-pay)

1. Client receives `Payment-Required` header
2. Reads `extra.partialTx` template (if present)
3. Extends template with funding inputs, signs
4. Sends `Payment-Signature` header with the raw tx
5. Server broadcasts via ARC
6. Client receives 200 + `Payment-Response` receipt

**On failure**: present "payment failed, retry?" option to the user. This is the simple deployment path.

### ProofGateway (BSV-proof)

1. Client receives `X402-Challenge` header
2. Reads `partial_tx_b64` template (Profile B, if present)
3. Extends template with funding inputs, signs
4. **Broadcasts the transaction to the BSV network**
5. Sends `X402-Proof` header with txid + rawtx
6. Server checks mempool, serves content

**On failure**: implement automatic retry logic. The client has already broadcast — the tx is either in mempool or it isn't. Retry the proof submission if the first attempt was a timing issue.

This is the enterprise path — the client handles broadcasting, the server stays stateless.

## Fee Delegation

For clients that don't hold BSV (zero-preload), a delegator service adds fee inputs:

1. Client constructs partial tx (payment output only, no fee inputs)
2. Client signs with `SIGHASH_ALL | ANYONECANPAY | FORKID` (`0xC1`)
3. Client sends partial tx to the delegator
4. Delegator appends fee inputs, signs only its fee inputs
5. Delegator returns completed transaction
6. Client proceeds with normal proof/payment flow

The delegator is between the client and the network — the server never talks to it. BSV transaction fees are negligible (1-50 sats), so fee delegation is a convenience, not a requirement.
