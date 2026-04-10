# x402-rack

Rack middleware for payment-gated HTTP using BSV and the [x402 protocol](https://docs.x402.org/).

The middleware is a pure dispatcher — it matches routes, issues payment challenges, and routes proofs to pluggable gateway backends for settlement. It has no blockchain knowledge and holds no keys.

## Four BSV settlement schemes

**Zero-config gateways** — enabled automatically when you set `wallet:`:

- [**BSV-pay**](schemes/bsv-pay.md) (Coinbase v2 headers) — server broadcasts via ARC. Partial transaction template, unique derived addresses per payment.
- [**BRC-121**](schemes/brc-121.md) (BSV Association `x-bsv-*` simple) — stateless server, BRC-100 wallet handles validation and replay detection via `internalize_action`. No PrefixStore, no challenge_secret, no nonce store.

**Specialist gateways** — explicit opt-in required:

- [**BRC-105**](schemes/brc-105.md) (BSV Association `x-bsv-payment-*`) — transitional; requires BRC-103 mutual authentication per spec. x402-rack accepts the client identity key via HTTP header as a stopgap until Ruby BRC-103 middleware lands.
- [**BSV-proof**](schemes/bsv-proof.md) (merkleworks x402) — experimental; client broadcasts, server checks mempool.

## Getting started

Add to your Gemfile:

```ruby
gem "x402-rack"
```

Set up a server wallet:

```bash
bundle exec rake x402:wallet:setup
```

The plug-and-play config:

```ruby
X402.configure do |c|
  c.domain = "api.example.com"
  c.wallet = X402::Wallet.load
  c.arc_url = "https://arc.taal.com"
  c.protect method: :GET, path: "/api/expensive", amount_sats: 100
end

use X402::Middleware
```

`BRC121Gateway` is auto-enabled whenever `wallet:` is set. `PayGateway` is also auto-enabled when `arc_url:` is available. Clients can pay via either protocol.

See the [Architecture](architecture.md) guide for how the pieces fit together, or jump to the [API Reference](reference/index.md) for class and method documentation.
