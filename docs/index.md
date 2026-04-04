# x402-rack

Rack middleware for payment-gated HTTP using BSV and the [x402 protocol](https://docs.x402.org/).

The middleware is a pure dispatcher — it matches routes, issues payment challenges, and routes proofs to pluggable gateway backends for settlement. It has no blockchain knowledge and holds no keys.

## Three BSV settlement schemes

- **BSV-pay** (Coinbase v2 headers) — server broadcasts via ARC. No nonces, minimal infrastructure.
- **BSV-proof** (merkleworks x402) — client broadcasts, server checks mempool. Nonce-bound, request-binding.
- **BRC-105** (BSV Association `x-bsv-*` headers) — BRC-29 key derivation for unique payment addresses. Works standalone or composes with BRC-103 mutual authentication.

## Getting started

Add to your Gemfile:

```ruby
gem "x402-rack", git: "https://github.com/sgbett/x402-rack.git"
```

See the [Architecture](architecture.md) guide for how the pieces fit together, or jump to the [API Reference](reference/index.md) for class and method documentation.
