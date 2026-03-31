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

### Configuration DSL (recommended)

The DSL handles shared dependencies (ARC client, payee script) and gateway
construction automatically. You declare *what* you want; the middleware builds it
at validation time.

```ruby
# config.ru or Rails initialiser
require "x402"

X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  # Shared ARC connection — built once, used by all gateways
  config.arc_url = "https://arc.taal.com"
  config.arc_api_key = "..."          # optional — ARC supports anonymous access

  # Enable gateways — constructed automatically from shared deps
  config.enable :pay_gateway
  config.enable :proof_gateway, nonce_provider: my_nonce_provider
  config.enable :brc105_gateway, server_wif: ENV["SERVER_WIF"]

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end

use X402::Middleware
```

#### Convenience options

Each gateway type supports convenience options that expand into their full form:

- **`:brc105_gateway`** — `server_wif: "L3..."` builds a `KeyDeriver` from a WIF
  string. `server_key:` accepts a `PrivateKey` directly. A default in-memory
  `PrefixStore` is used if `prefix_store:` is not provided.
- **`:proof_gateway`** — `nonce_wif: "L3..."` builds a `PrivateKey` for the
  `nonce_key:` parameter.
- **`:pay_gateway`** — pass-through options: `arc_wait_for:`, `arc_timeout:`,
  `binding_mode:`, `wallet:`, `challenge_secret:`.

#### Per-gateway overrides

Any gateway can override shared dependencies:

```ruby
config.enable :pay_gateway, arc_client: my_custom_arc
config.enable :proof_gateway, nonce_provider: np, payee_locking_script_hex: "deadbeef..."
```

#### Order independence

`enable` records gateway specs; construction is deferred to `validate!`. This
means `arc_url` can be set after `enable` calls — order within the configure
block does not matter.

### Manual gateway construction (power-user escape hatch)

For full control, construct gateways yourself and assign them directly. This
bypasses DSL construction entirely and works exactly as before:

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  config.gateways = [
    X402::BSV::PayGateway.new(
      arc_client: BSV::Network::ARC.new("https://arc.taal.com", api_key: "..."),
      payee_locking_script_hex: "76a914...88ac"
    ),
    X402::BSV::BRC105Gateway.new(
      key_deriver: BSV::Wallet::KeyDeriver.new(server_private_key),
      prefix_store: X402::BSV::PrefixStore::Memory.new,
      arc_client: arc_client
    )
  ]

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end

use X402::Middleware
```

If `config.gateways` is set to a non-empty array, any `enable` calls are
ignored.

## How It Works

1. Client requests a protected resource
2. Middleware returns `402 Payment Required` with challenge headers from each configured gateway
3. Client constructs a BSV payment transaction and retries with proof
4. Middleware dispatches the proof to the matching gateway for settlement
5. Gateway verifies and settles — middleware serves or rejects

Three BSV settlement schemes are supported:

- **BSV-pay** (Coinbase v2 headers) — server broadcasts via ARC. No nonces, minimal infrastructure.
- **BSV-proof** (merkleworks x402) — client broadcasts, server checks mempool. Nonce-bound, request-binding.
- **BRC-105** (BSV Association `x-bsv-*` headers) — BRC-29 key derivation for unique payment addresses. Works standalone or composes with BRC-103 mutual authentication.

BSV-pay and BSV-proof produce partial transaction templates that clients extend. BRC-105 uses a different model — the client builds the entire transaction using BRC-29 derived addresses. See [DESIGN.md](DESIGN.md) for details.

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
