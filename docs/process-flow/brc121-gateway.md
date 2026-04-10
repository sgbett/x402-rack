# BRC121Gateway Process Flow

## Sequence

```
 Flow        | N | From    →  To      |   | HTTP                           | x-bsv Headers                          | Body
-------------|---|--------------------|---|--------------------------------|-----------------------------------------|-----------------------------
  │          | 1 | client  →  server  |   | GET /protected                 |                                         |
  │          | 2 | server  →  client  | ⚠ | HTTP/1.1 402 Payment Required  | x-bsv-sats: 100                         |
  │          |   |                    |   |                                | x-bsv-server: 02ab...cd                 |
  │          | 3 | client  →  server  |   | GET /protected                 | x-bsv-beef: <base64 BEEF>               |
  │          |   |                    |   |                                | x-bsv-sender: 03cd...ef                 |
  │          |   |                    |   |                                | x-bsv-nonce: <base64 derivation prefix> |
  │          |   |                    |   |                                | x-bsv-time: 1719500000000               |
  │          |   |                    |   |                                | x-bsv-vout: 0                           |
  │          | 4 | server  →  wallet  |   | internalize_action(...)        |                                         |
  ├─ ok      | 5 | wallet  →  server  |   | { accepted: true }             |                                         |
  │   └─ 200 | 6 | server  →  client  |   | HTTP/1.1 200 OK                | x-bsv-payment-satoshis-paid: 100        | <protected content>
  ├─ stale   | 7 | server  →  client  | ✗ | HTTP/1.1 402 Payment Required  |                                         | { "error": "x-bsv-time outside 30s freshness window" }
  └─ replay  | 8 | server  →  client  | ✗ | HTTP/1.1 402 Payment Required  |                                         | { "error": "replay: transaction already settled" }

⚠ Expected (402 Challenge)
✗ Error paths
```

## Sequence Diagram

```mermaid
sequenceDiagram
  autonumber
  participant client as BSV Browser<br/>---<br/>BRC-100 Wallet
  participant server as Server<br/>---<br/>x402-rack<br/>BRC121Gateway
  participant wallet as Server Wallet<br/>---<br/>BSV::Wallet::WalletClient

  client->>server: GET /protected

  Note over server: no x-bsv-beef header<br/>→ issue 402 challenge

  server->>client: HTTP/1.1 402 Payment Required<br/>x-bsv-sats: 100<br/>x-bsv-server: 02ab...cd

  Note over client: build BRC-29 payment:<br/>derive recipient pubkey from<br/>(server identity key, prefix, base64(time))<br/>construct P2PKH output<br/>wrap in BEEF

  client->>server: GET /protected<br/>x-bsv-beef: &lt;base64 BEEF&gt;<br/>x-bsv-sender: 03cd...ef<br/>x-bsv-nonce: &lt;base64 prefix&gt;<br/>x-bsv-time: 1719500000000<br/>x-bsv-vout: 0

  Note over server: 1. all 5 headers present?<br/>2. x-bsv-time within 30s?<br/>3. decode BEEF<br/>4. txid not in TxidStore?<br/>5. output[vout].satoshis ≥ 100?

  server->>wallet: internalize_action({<br/>  tx: ...,<br/>  outputs: [{ output_index, protocol,<br/>    payment_remittance: { derivation_prefix,<br/>      derivation_suffix, sender_identity_key }}],<br/>  description: "BRC-121 payment"<br/>})

  wallet->>server: { accepted: true }

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
| Round trips | 1 (after BRC-103 handshake) | 1 (no handshake) |
