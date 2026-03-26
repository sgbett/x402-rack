# x402-rack

Rack middleware for payment-gated HTTP using BSV (Bitcoin SV) and the [x402 protocol](https://docs.x402.org/).

The middleware is a pure dispatcher — it matches routes, issues payment challenges, and routes proofs to pluggable gateway backends for settlement. It has no blockchain knowledge and holds no keys.

## Status

Early development (v0.1.0). Architecture is defined; gateway implementation is in progress. See [DESIGN.md](DESIGN.md) for architecture notes.

**This is pre-release software and should not be used for real-world monetary purposes.**

## Installation

Add to your Gemfile:

```ruby
gem "x402-rack", git: "https://github.com/sgbett/x402-rack.git"
```

## Usage

```ruby
# config.ru or Rails initialiser
require "x402"

X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  config.gateways = [
    X402::BSV::PayGateway.new(
      arc_url: "https://arc.taal.com",
      arc_api_key: "..."
    )
  ]

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end

use X402::Middleware
```

## How It Works

1. Client requests a protected resource
2. Middleware returns `402 Payment Required` with challenge headers from each configured gateway
3. Client constructs a BSV payment transaction and retries with proof
4. Middleware dispatches the proof to the matching gateway for settlement
5. Gateway verifies and settles — middleware serves or rejects

Two BSV settlement schemes are supported:

- **BSV-pay** (Coinbase v2 headers) — server broadcasts via ARC. No nonces, minimal infrastructure.
- **BSV-proof** (merkleworks x402) — client broadcasts, server checks mempool. Nonce-bound, request-binding.

Both gateways produce partial transaction templates that clients extend by adding funding inputs. See [DESIGN.md](DESIGN.md) for details.

## Development

```bash
bin/setup              # Install dependencies
bundle exec rake spec  # Run tests
bundle exec rubocop    # Lint
bundle exec rake       # Run all checks (tests + lint)
```

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/sgbett/x402-rack).

## Licence

Available under the terms of the [Open BSV Licence](https://github.com/sgbett/x402-rack/blob/master/LICENSE.txt).
