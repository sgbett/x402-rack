# BRC105Gateway Process Flow

## Sequence (Standalone Mode)

```
 Flow        | N | From    →  To      |   | HTTP                           | x-bsv Headers                                    | Body
-------------|---|-------------------|---|--------------------------------|-------------------------------------------------|-----------------------------
  │          | 1 | client  →  server |   | GET /protected                 |                                                  |
 402         | 2 | server  →  client | ⚠ | HTTP/1.1 402 Payment Required  | x-bsv-payment-satoshis-required: 100             | { "error": "Payment Required" }
  │          |   |                    |   |                                | x-bsv-payment-derivation-prefix: a1b2...         |
  │          |   |                    |   |                                | x-bsv-payment-identity-key: 02ab...cd            |
  │          | 3 | client  →  ARC    |   | POST /v1/tx                    |                                                  | <BEEF bytes>
  │          | 4 | ARC     →  client |   | HTTP/1.1 200                   |                                                  | { "txid": "...", ... }
  │          | 5 | client  →  server |   | GET /protected                 | x-bsv-payment: [1]                               |
  │          | 6 | server  →  ARC    |   | GET /v1/tx/{txid}              |                                                  |
  ├─ 200     | 7 | ARC     →  server |   | HTTP/1.1 200                   |                                                  | { "txid": "...", "txStatus": "..." }
  │   └─ 200 | 8 | server  →  client |   | HTTP/1.1 200 OK                | x-bsv-payment-result: [2]                        | <protected content>
  └─ XXX     | 7 | ARC     →  server | ✗ | HTTP/1.1 404/5xx               |                                                  | { "status": XXX, ... }
      └─ 402 | 8 | server  →  client | ✗ | HTTP/1.1 402                   |                                                  | { "error": "payment not accepted" }

Key:

[1] JSON: { "derivationPrefix": "a1b2...", "derivationSuffix": "f7e8...", "transaction": "<base64 AtomicBEEF>" }
[2] base64(JSON: { "success": true, "transaction": "<txid>", "network": "bsv:mainnet" })

⚠ Expected (402 Challenge)
✗ ARC status check failed — tx not on-chain
```

## Sequence Diagram (Standalone Mode)

```mermaid
sequenceDiagram
  autonumber
  participant client as BSV Browser<br/>---<br/>BRC-100 Wallet
  participant server as Server<br/>---<br/>x402-rack
  participant arc as ARCADE<br/>---<br/>arcade.gorillapool.io

  client->>server: GET /protected

  server->>client: HTTP/1.1 402 Payment Required<br/>x-bsv-payment-satoshis-required: 100<br/>x-bsv-payment-derivation-prefix: a1b2...<br/>x-bsv-payment-identity-key: 02ab...cd

  Note over client: Derive payment address via BRC-29:<br/>protocol [2, "3241645161d8"]<br/>key_id = "prefix suffix"<br/>counterparty = server identity key

  Note over client: Build transaction paying to<br/>derived P2PKH address<br/>Broadcast to ARC (client responsibility)

  client->>arc: POST /v1/tx (broadcast)
  arc->>client: 200 OK

  client->>server: GET /protected<br/>x-bsv-payment: { derivationPrefix, derivationSuffix, transaction }

  activate server
  Note over server: Parse JSON + validate fields<br/>Parse BEEF → extract subject tx<br/>Re-derive expected P2PKH<br/>Verify payment output >= amount

  server->>arc: GET /v1/tx/{txid} (status check)
  activate arc
  arc->>server: 200 OK — tx known
  deactivate arc

  Note over server: Consume prefix (replay protection)<br/>wallet.internalize_action(...)

  alt ARC confirms tx
    server->>client: HTTP/1.1 200 OK<br/>x-bsv-payment-result: base64(result JSON)<br/><protected content>
  else ARC rejects / not found
    server->>client: HTTP/1.1 402<br/>{ "error": "payment not accepted" }
  else ARC outage
    server->>client: HTTP/1.1 503<br/>{ "error": "payment verification temporarily unavailable" }
  end
  deactivate server
```

## Sequence Diagram (Authenticated Mode — with BRC-103)

```mermaid
sequenceDiagram
  autonumber
  participant client as BSV Browser<br/>---<br/>BRC-100 Wallet
  participant brc103 as BRC-103 Middleware<br/>---<br/>Mutual Auth
  participant server as BRC105Gateway<br/>---<br/>x402-rack
  participant arc as ARCADE

  Note over client,brc103: BRC-103 handshake (prior)<br/>Identity keys exchanged

  client->>brc103: GET /protected<br/>x-bsv-auth-*: session headers
  brc103->>server: GET /protected<br/>env['brc103.identity_key'] = client_pubkey

  server->>brc103: HTTP/1.1 402 Payment Required<br/>x-bsv-payment-satoshis-required: 100<br/>x-bsv-payment-derivation-prefix: a1b2...
  brc103->>client: 402 (no identity-key header — client has it from handshake)

  Note over client: Derive payment address via BRC-29<br/>counterparty = server identity key<br/>(from BRC-103 session, not header)<br/>Build tx, broadcast to ARC

  client->>brc103: GET /protected<br/>x-bsv-payment: { ... }
  brc103->>server: env['brc103.identity_key'] = client_pubkey

  activate server
  Note over server: Counterparty = client_pubkey<br/>(not "anyone")<br/>Validate, verify on-chain, consume, internalise

  server->>arc: GET /v1/tx/{txid}
  activate arc
  arc->>server: 200 OK
  deactivate arc

  server->>brc103: HTTP/1.1 200 OK<br/>x-bsv-payment-result: ...
  brc103->>client: 200 OK + protected content
  deactivate server
```

## Notes

- **Client broadcasts, server verifies** — per BRC-105 §6.3: "the client is expected to construct and broadcast." The server calls `arc_client.status(txid)` to confirm the tx is on-chain.
- **No partial template** — unlike PayGateway and ProofGateway, the server does not provide a pre-built transaction. The client derives the payment address and builds the entire transaction.
- **No OP_RETURN** — request binding is implicit via the derivation prefix (unique per challenge, server-tracked).
- **AtomicBEEF** — transactions are in BRC-95 format (includes merkle proofs), not raw bytes.
- **Prefix consumed after verification** — the derivation prefix is consumed only after BEEF parsing, derivation verification, payment output checks, and ARC status confirmation. This prevents both garbage-burning and unbroadcast-tx attacks.
- **BRC-103 detection is automatic** — the gateway checks `env['brc103.identity_key']` for a valid compressed pubkey hex. If present, authenticated mode; otherwise, standalone.
