# x402-rack Design

Full documentation is in [`docs/`](docs/). This file serves as an index.

## Architecture

The middleware is a pure dispatcher — no blockchain knowledge, no keys. Gateways handle settlement.

→ [docs/architecture.md](docs/architecture.md)

## Settlement Schemes

Two BSV payment schemes, both producing partial transaction templates:

- **BSV-pay** — server broadcasts via ARC. Coinbase v2 headers. Minimal infrastructure.
  → [docs/schemes/bsv-pay.md](docs/schemes/bsv-pay.md)

- **BSV-proof** — client broadcasts, server checks mempool. Merkleworks headers. Nonce-bound.
  → [docs/schemes/bsv-proof.md](docs/schemes/bsv-proof.md)

## Security

HMAC payToSig, nonce provenance verification (0xC3), OP_RETURN binding, threat model.

→ [docs/security.md](docs/security.md)

## Operations

- **Deployment**: configuration, ARC setup, rate limiting → [docs/operations/deployment.md](docs/operations/deployment.md)
- **Performance**: benchmarks, scaling trade-offs, ARC bottleneck → [docs/operations/performance.md](docs/operations/performance.md)
- **Treasury**: nonce UTXO lifecycle, expiry, miner sweep → [docs/operations/treasury.md](docs/operations/treasury.md)

## Ecosystem

Coinbase v2, merkleworks, BRC-105. Header namespaces. Our position.

→ [docs/ecosystem.md](docs/ecosystem.md)

## Client Integration

bsv-x402, BRC-100/CWI, BSV Browser, retry logic, fee delegation.

→ [docs/client-integration.md](docs/client-integration.md)

## Process Flows

- **PayGateway**: [docs/process-flow/pay-gateway.md](docs/process-flow/pay-gateway.md)
