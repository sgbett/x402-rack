# x402-rack

Rack middleware for payment-gated HTTP using BSV (Bitcoin SV) and the [x402 protocol](https://docs.x402.org/).

The middleware is a pure dispatcher — it matches routes, issues payment challenges, and routes proofs to pluggable gateway backends for settlement. It has no blockchain knowledge and holds no keys.

## Installation

```ruby
# Gemfile
gem "x402-rack"
```

```bash
bundle install
```

## Quick start

Set up a server wallet:

```bash
bundle exec rake x402:wallet:setup
```

> **Rails** apps get the task automatically via the Railtie. **Non-Rails** Rack
> apps need one line in their `Rakefile`:
>
> ```ruby
> load "x402/tasks/x402.rake"
> ```

Then add the middleware:

```ruby
# config.ru or Rails initialiser
require "x402"

X402.configure do |config|
  config.domain = "api.example.com"
  config.wallet = X402::Wallet.load
  config.arc_url = "https://arc.taal.com"

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end

use X402::Middleware
```

That's it. With `wallet:` set and no explicit `enable` calls, gateways are auto-wired based on what's configured:

- **`BRC121Gateway`** — always enabled when `wallet:` is set (truly zero-config — no ARC needed)
- **`PayGateway`** — also enabled when `arc_url:` (or `arc_client:`) is available

Clients can pay using whichever protocol they support; the middleware dispatches on proof header.

## Gateways

| Gateway | Setup required | Status |
|---------|----------------|--------|
| `PayGateway` (Coinbase v2) | None — auto-enabled | Stable |
| `BRC121Gateway` (BRC-121) | None — auto-enabled | Stable |
| `BRC105Gateway` (BRC-105) | Requires BRC-103 middleware per spec; transitional HTTP-header stopgap for now | Transitional |
| `ProofGateway` (merkleworks) | Experimental | Under development |

`BRC121Gateway` is truly zero-config — it only needs a wallet. `PayGateway` is auto-enabled when `arc_url` is also set. `BRC105Gateway` and `ProofGateway` are opt-in via `config.enable`.

## Advanced configuration

### Explicit gateway enablement

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.wallet = X402::Wallet.load
  config.arc_url = "https://arc.taal.com"

  config.enable :pay_gateway                           # explicit, same as default
  config.enable :brc105_gateway                        # opt in to BRC-105
  config.enable :proof_gateway, nonce_provider: my_np  # opt in to ProofGateway
end
```

If any `config.enable` calls are made, the auto-enable is skipped — you get exactly what you asked for.

### Per-gateway overrides

```ruby
config.enable :pay_gateway, arc_client: my_custom_arc
config.enable :brc121_gateway, wallet: alt_wallet
```

### Manual gateway construction (power-user escape hatch)

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.gateways = [
    X402::BSV::PayGateway.new(
      arc_client: BSV::Network::ARC.new("https://arc.taal.com", api_key: "..."),
      wallet: my_wallet
    ),
    X402::BSV::BRC121Gateway.new(wallet: my_wallet)
  ]
  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end
```

When `config.gateways` is set, any `enable` calls and the auto-enable are ignored.

### Wallet options

`X402::Wallet.load` resolves the signing key in this order:

1. `SERVER_WIF` environment variable (wins if set)
2. `~/.bsv-wallet/wallet.key` (or `BSV_WALLET_DIR/wallet.key`) — written by `rake x402:wallet:setup`
3. Raises `ConfigurationError` suggesting the setup task

The Rake task never overwrites an existing `wallet.key`. Pass `FORCE=1` to replace an existing wallet (destructive).

Backwards-compat alternatives still work: `config.server_wif = ENV["SERVER_WIF"]` or `config.payee_locking_script_hex = "76a914...88ac"`.

## How It Works

1. Client requests a protected resource
2. Middleware returns `402 Payment Required` with challenge headers from each configured gateway
3. Client constructs a BSV payment transaction and retries with proof
4. Middleware dispatches the proof to the matching gateway for settlement
5. Gateway verifies and settles — middleware serves or rejects

Four BSV settlement schemes are supported:

- **BSV-pay** (Coinbase v2 headers) — server broadcasts via ARC. Partial transaction template, unique derived addresses per payment.
- **BRC-121** (BSV Association simple) — stateless, BRC-100 wallet-native, zero config.
- **BRC-105** (BSV Association authenticated) — transitional; requires BRC-103 for spec compliance.
- **BSV-proof** (merkleworks) — experimental; client broadcasts, server checks mempool.

See [CHANGELOG.md](CHANGELOG.md) for release history and [docs/](docs/) for full documentation.

## Development

```bash
bin/setup               # Install dependencies
bundle exec rake spec   # Run unit and integration tests
bundle exec rubocop     # Lint
bundle exec rake        # Run all checks (tests + lint)
bundle exec rake e2e    # Run BSV testnet e2e tests (requires ARC + funded wallets)
bundle exec rake feature # Run browser feature tests (requires Chrome for Testing + bsv-x402 extension)
```

### Feature specs (browser)

Feature specs drive a real Chrome browser with the [bsv-x402](https://github.com/sgbett/bsv-x402) extension side-loaded. Google Chrome stable silently refuses `--load-extension`, so a separate automation build is required:

```bash
npx @puppeteer/browsers install chrome@stable \
  --path=$HOME/.cache/chrome-for-testing
npx @puppeteer/browsers install chromedriver@stable \
  --path=$HOME/.cache/chrome-for-testing
bundle install --with feature
bundle exec rake feature
```

Set `BSV_X402_EXTENSION_PATH` to override the default extension location. Set `HEADED=1` to launch Chrome in headed mode for debugging.

## Contributing

Bug reports and pull requests are welcome on [GitHub](https://github.com/sgbett/x402-rack).

## Licence

Available under the terms of the [Open BSV Licence](https://github.com/sgbett/x402-rack/blob/master/LICENSE.txt).
