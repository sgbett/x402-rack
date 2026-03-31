# BRC105Gateway Process Flow

## Sequence (Standalone Mode)

```
 Flow        | N | From    →  To      |   | HTTP                           | x-bsv Headers                                    | Body
-------------|---|-------------------|---|--------------------------------|-------------------------------------------------|-----------------------------
  │          | 1 | client  →  server |   | GET /protected                 |                                                  |
 402         | 2 | server  →  client | ⚠ | HTTP/1.1 402 Payment Required  | x-bsv-payment-satoshis-required: 100             | { "error": "Payment Required" }
  │          |   |                    |   |                                | x-bsv-payment-derivation-prefix: a1b2...         |
  │          |   |                    |   |                                | x-bsv-payment-identity-key: 02ab...cd            |
  │          | 3 | client  →  server |   | GET /protected                 | x-bsv-payment: [1]                               |
  │          | 4 | server  →  ARC    |   | POST /v1/tx                    |                                                  | <raw tx bytes>
  ├─ 200     | 5 | ARC     →  server |   | HTTP/1.1 200                   |                                                  | { "txid": "...", ... }
  │   └─ 200 | 6 | server  →  client |   | HTTP/1.1 200 OK                | x-bsv-payment-result: [2]                        | <protected content>
  └─ XXX     | 7 | ARC     →  server | ✗ | HTTP/1.1 XXX ...               |                                                  | { "status": XXX, ... }
      └─ 502 | 8 | server  →  client | ✗ | HTTP/1.1 502                   |                                                  | { "error": "ARC broadcast failed" }

Key:

[1] JSON: { "derivationPrefix": "a1b2...", "derivationSuffix": "f7e8...", "transaction": "<base64 AtomicBEEF>" }
[2] base64(JSON: { "success": true, "transaction": "<txid>", "network": "bsv:mainnet" })

⚠ Expected (402 Challenge)
✗ ARC rejection
```

## Sequence Diagram (Standalone Mode)

```mermaid
sequenceDiagram
  autonumber
  participant client as BSV Browser<br/>---<br/>BRC-100 Wallet
  participant server as Server<br/>---<br/>x402-rack
  participant arc as ARC Endpoint<br/>---<br/>bitcoin-sv/arc

  client->>server: GET /protected

  server->>client: HTTP/1.1 402 Payment Required<br/>x-bsv-payment-satoshis-required: 100<br/>x-bsv-payment-derivation-prefix: a1b2...<br/>x-bsv-payment-identity-key: 02ab...cd

  Note over client: Derive payment address via BRC-29:<br/>protocol [2, "3241645161d8"]<br/>key_id = "prefix suffix"<br/>counterparty = server identity key

  Note over client: Build transaction paying to<br/>derived P2PKH address<br/>Encode as AtomicBEEF (BRC-95)

  client->>server: GET /protected<br/>x-bsv-payment: { derivationPrefix, derivationSuffix, transaction }

  activate server
  Note over server: Parse JSON + validate fields<br/>Parse AtomicBEEF<br/>Re-derive expected P2PKH<br/>Verify payment output >= amount<br/>Consume prefix (replay protection)

  server->>arc: POST /v1/tx<br/><raw tx bytes>
  activate arc
  arc->>server: HTTP/1.1 200 OK<br/>{ "txid": "...", "txStatus": "SEEN_ON_NETWORK" }
  deactivate arc

  alt ARC 200 (accepted)
    server->>client: HTTP/1.1 200 OK<br/>x-bsv-payment-result: base64(result JSON)<br/><protected content>
  else ARC error
    server->>client: HTTP/1.1 502<br/>{ "error": "ARC broadcast failed" }
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
  participant arc as ARC Endpoint<br/>---<br/>bitcoin-sv/arc

  Note over client,brc103: BRC-103 handshake (prior)<br/>Identity keys exchanged

  client->>brc103: GET /protected<br/>x-bsv-auth-*: session headers
  brc103->>server: GET /protected<br/>env['brc103.identity_key'] = client_pubkey

  server->>brc103: HTTP/1.1 402 Payment Required<br/>x-bsv-payment-satoshis-required: 100<br/>x-bsv-payment-derivation-prefix: a1b2...
  brc103->>client: 402 (no identity-key header — client has it from handshake)

  Note over client: Derive payment address via BRC-29<br/>counterparty = server identity key<br/>(from BRC-103 session, not header)

  client->>brc103: GET /protected<br/>x-bsv-payment: { ... }
  brc103->>server: env['brc103.identity_key'] = client_pubkey

  activate server
  Note over server: Counterparty = client_pubkey<br/>(not "anyone")<br/>Derive, verify, consume, broadcast

  server->>arc: POST /v1/tx
  activate arc
  arc->>server: 200 OK
  deactivate arc

  server->>brc103: HTTP/1.1 200 OK<br/>x-bsv-payment-result: ...
  brc103->>client: 200 OK + protected content
  deactivate server
```

## Notes

- **Server broadcasts, not client** — like PayGateway. The server receives the AtomicBEEF and broadcasts.
- **No partial template** — unlike PayGateway and ProofGateway, the server does not provide a pre-built transaction. The client derives the payment address and builds the entire transaction.
- **No OP_RETURN** — request binding is implicit via the derivation prefix (unique per challenge, server-tracked).
- **AtomicBEEF** — transactions are in BRC-95 format (includes merkle proofs), not raw bytes.
- **Prefix consumed after validation** — the derivation prefix is consumed only after BEEF parsing, derivation verification, and payment output checks. This prevents a MITM from burning a legitimate prefix with garbage.
- **BRC-103 detection is automatic** — the gateway checks `env['brc103.identity_key']` for a valid compressed pubkey hex. If present, authenticated mode; otherwise, standalone.
