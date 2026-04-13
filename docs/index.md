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

### Minimal: relay to an existing wallet

The simplest path — no keys, no local wallet. Point `operator_wallet_url` at an existing `@bsv/simple` server wallet:

```ruby
X402.configure do |c|
  c.domain = "api.example.com"
  c.operator_wallet_url = "https://my-wallet.example.com/api/server-wallet"
  c.protect method: :GET, path: "/api/data", amount_sats: 100
end

use X402::Middleware
```

PayGateway is auto-enabled. ARC defaults to ARCADE. The server holds no private keys.

### With a local wallet (enables BRC-121)

```bash
bundle exec rake x402:wallet:setup
```

```ruby
X402.configure do |c|
  c.domain = "api.example.com"
  c.wallet = X402::Wallet.load
  c.protect method: :GET, path: "/api/data", amount_sats: 100
end

use X402::Middleware
```

Both PayGateway and BRC121Gateway are auto-enabled. ARC defaults to ARCADE.

### With a remote wallet for all gateways

```ruby
X402.configure do |c|
  c.domain = "api.example.com"
  c.wallet = X402::RemoteWallet.new(url: "https://my-wallet.example.com/api/server-wallet")
  c.protect method: :GET, path: "/api/data", amount_sats: 100
end

use X402::Middleware
```

`RemoteWallet` implements the same duck-typed interface as the local wallet, so all gateways (PayGateway, BRC-121, BRC-105) work with it.

See the [Architecture](architecture.md) guide for how the pieces fit together, or jump to the [API Reference](reference/index.md) for class and method documentation.
