# BRC121Gateway Process Flow

## Sequence

```
 Flow        | N | From    →  To      |   | HTTP                           | x-bsv Headers                          | Body
-------------|---|--------------------|---|--------------------------------|-----------------------------------------|-----------------------------
  │          | 1 | client  →  server  |   | GET /protected                 |                                         |
  │          | 2 | server  →  client  | ⚠ | HTTP/1.1 402 Payment Required  | x-bsv-sats: 100                         |
  │          |   |                    |   |                                | x-bsv-server: 02ab...cd                 |
  │          | 3 | client  →  ARC     |   | POST /v1/tx (client broadcasts)|                                         | <BEEF bytes>
  │          | 4 | ARC     →  client  |   | HTTP/1.1 200                   |                                         | { "txid": "...", ... }
  │          | 5 | client  →  server  |   | GET /protected                 | x-bsv-beef: <base64 BEEF>               |
  │          |   |                    |   |                                | x-bsv-sender: 03cd...ef                 |
  │          |   |                    |   |                                | x-bsv-nonce: <base64 derivation prefix> |
  │          |   |                    |   |                                | x-bsv-time: 1719500000000               |
  │          |   |                    |   |                                | x-bsv-vout: 0                           |
  │          | 6 | server  →  ARC     |   | GET /v1/tx/{txid} (status)     |                                         |
  ├─ ok      | 7 | ARC     →  server  |   | HTTP/1.1 200 — tx known        |                                         |
  │          | 8 | server  →  wallet  |   | internalize_action(...)        |                                         |
  │   └─ 200 | 9 | server  →  client  |   | HTTP/1.1 200 OK                | x-bsv-payment-satoshis-paid: 100        | <protected content>
  ├─ no pay  | 7 | ARC     →  server  | ✗ | HTTP/1.1 404 — tx not found    |                                         |
  │   └─ 402 | 8 | server  →  client  | ✗ | HTTP/1.1 402                   |                                         | { "error": "payment not accepted" }
  ├─ stale   |   | server  →  client  | ✗ | HTTP/1.1 402                   |                                         | { "error": "x-bsv-time outside 30s freshness window" }
  └─ replay  |   | server  →  client  | ✗ | HTTP/1.1 402                   |                                         | { "error": "replay: transaction already settled" }

⚠ Expected (402 Challenge)
✗ Error paths
```

## Sequence Diagram

```mermaid
sequenceDiagram
  autonumber
  participant client as BSV Browser<br/>---<br/>BRC-100 Wallet
  participant server as Server<br/>---<br/>x402-rack<br/>BRC121Gateway
  participant arc as ARCADE
  participant wallet as Server Wallet<br/>---<br/>BSV::Wallet::Client

  client->>server: GET /protected

  Note over server: no x-bsv-beef header<br/>→ issue 402 challenge

  server->>client: HTTP/1.1 402 Payment Required<br/>x-bsv-sats: 100<br/>x-bsv-server: 02ab...cd

  Note over client: build BRC-29 payment:<br/>derive recipient pubkey from<br/>(server identity key, prefix, base64(time))<br/>construct P2PKH output<br/>wrap in BEEF<br/>broadcast to ARC

  client->>arc: POST /v1/tx (broadcast)
  arc->>client: 200 OK

  client->>server: GET /protected<br/>x-bsv-beef: &lt;base64 BEEF&gt;<br/>x-bsv-sender: 03cd...ef<br/>x-bsv-nonce: &lt;base64 prefix&gt;<br/>x-bsv-time: 1719500000000<br/>x-bsv-vout: 0

  Note over server: 1. all 5 headers present?<br/>2. x-bsv-time within 30s?<br/>3. decode BEEF<br/>4. output[vout].satoshis ≥ 100?

  server->>arc: GET /v1/tx/{txid} (status check)
  arc->>server: 200 OK — tx known

  Note over server: 5. txid not in TxidStore?

  server->>wallet: internalize_action({<br/>  tx: ...,<br/>  outputs: [{ output_index, protocol,<br/>    payment_remittance: { derivation_prefix,<br/>      derivation_suffix, sender_identity_key }}],<br/>  description: "BRC-121 payment"<br/>})

  wallet->>server: { accepted: true }

  Note over server: 6. check isMerge (§5 step 5)

  server->>client: HTTP/1.1 200 OK<br/>x-bsv-payment-satoshis-paid: 100<br/><protected content>
```

## Key differences vs BRC-105

| Aspect | BRC-105 | BRC-121 |
|--------|---------|---------|
| Authentication | Requires BRC-103 handshake | None (stateless) |
| Derivation prefix | Server-generated, stored | Client-generated |
| Derivation suffix | Client-chosen | `base64(unix_ms_timestamp)` |
| Server state | PrefixStore | None (+ TxidStore as replay belt-and-braces) |
| Transaction format | AtomicBEEF in JSON envelope | Raw BEEF in `x-bsv-beef` header |
| Replay protection | Server-tracked prefix consumption | 30s timestamp + wallet `isMerge` |
| Who broadcasts | Client (§6.3) | Client (§5) |
| Server ARC usage | `arc_client.status(txid)` | `arc_client.status(txid)` |
| Round trips | 1 (after BRC-103 handshake) | 1 (no handshake) |
