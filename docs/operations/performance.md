# Performance

## Benchmarks

### Challenge Generation

PayGateway challenge header generation is fast — the bottleneck is never the middleware:

- **10,000 challenge headers in ~63ms** (PayGateway, no wallet derivation)
- Address derivation (via wallet) adds ~1ms per challenge
- ProofGateway template signing (0xC3) adds ~2-3ms per challenge (ECDSA signing)

### ARC Latency

The real bottleneck is ARC acceptance. Typical latencies:

| ARC Status | Meaning | Typical Latency |
|-----------|---------|-----------------|
| `STORED` | ARC has it, will retry | Milliseconds |
| `SENT_TO_NETWORK` | At least 1 node has it | Sub-second |
| `ACCEPTED_BY_NETWORK` | A node accepted (ZMQ) | ~1 second |
| `SEEN_ON_NETWORK` | Propagated to multiple nodes | 1-3 seconds |
| `MINED` | In a block | ~10 minutes |

Default: `SEEN_ON_NETWORK` with 5s timeout. Configurable per gateway.

## Scaling Trade-offs

### PayGateway (BSV-pay)

- **Challenge generation**: fast (no nonces, no signing)
- **Settlement**: synchronous ARC broadcast — server holds connection open
- **Bottleneck**: ARC round-trip (broadcast) on every request
- **Scaling**: limited by ARC throughput per server instance
- **Best for**: simple deployments, low-to-medium traffic, getting started

### BRC121Gateway / BRC105Gateway

- **Challenge generation**: fast (BRC-121: two headers; BRC-105: prefix + identity key)
- **Settlement**: ARC status check (GET, not POST) — lighter than broadcast
- **Bottleneck**: ARC round-trip (status query) on every request
- **Scaling**: broadcast distributed to clients; server does a lightweight read
- **Best for**: BRC-100 wallet ecosystems, spec-compliant deployments

### ProofGateway (BSV-proof)

- **Challenge generation**: slower (nonce provision + 0xC3 signing)
- **Settlement**: fast (just a mempool status check)
- **Bottleneck**: nonce provision (horizontally scalable)
- **Scaling**: broadcast distributed to clients, server is passive observer
- **Best for**: high traffic, enterprise deployments, horizontal scaling

### Scaling Comparison

In PayGateway, the server broadcasts every transaction (POST to ARC). Under load, ARC connections stack up.

In BRC-121, BRC-105, and ProofGateway, the client broadcasts and the server verifies via a status query (GET from ARC). The server's ARC interaction is lighter — a read, not a write. The heavy lifting (transaction construction, signing, broadcasting) is distributed across all clients.

For ProofGateway specifically, the nonce provider can be horizontally scaled independently — it's just minting 1-sat UTXOs, which is fast and parallelisable.

## Mitigation Strategies

### ARC Timeout

The 5-second default timeout protects against ARC slowness. If ARC doesn't respond:
- PayGateway: returns 504 Gateway Timeout
- ProofGateway: returns 502 (mempool check failed)

Lower-value endpoints could use `ACCEPTED_BY_NETWORK` for faster response at slightly reduced certainty.

### Rate Limiting

Not the middleware's concern — handle at nginx or via `Rack::Attack`. See [deployment.md](deployment.md).

### Connection Pooling

For high-traffic PayGateway deployments, consider HTTP connection pooling to ARC:

```ruby
# Use a persistent HTTP client
http_client = Net::HTTP::Persistent.new
arc = BSV::Network::ARC.new("https://arcade.gorillapool.io",
                            api_key: "...",
                            http_client: http_client)
```

The SDK's ARC client accepts an injectable HTTP client for exactly this purpose.
