# x402-rack

Rack middleware for payment-gated HTTP using BSV (Bitcoin SV) and the [x402 protocol](https://docs.x402.org/).

The middleware is a pure dispatcher — it matches routes, issues payment challenges, and routes proofs to pluggable gateway backends for settlement. It has no blockchain knowledge and holds no keys.

## What x402-rack guarantees

> **x402-rack serves content if and only if the vendor has broadcast the payment transaction to the BSV network.**

That is the whole job. `BRC121Gateway` and `BRC105Gateway` broadcast the client's signed BEEF to ARC themselves, after the payment output has been verified but **before** any wallet or replay state is mutated. The broadcast is idempotent — a client that already broadcast is fine; ARC treats the duplicate as a no-op. This matches BSV's native commerce model: the vendor is the settlement point.

`ProofGateway` keeps its original semantics (client broadcasts first, server reads ARC status) because the scheme is explicitly proof-of-prior-payment. Every other gateway broadcasts.

Two failure modes are distinguished in the HTTP response:

- **`402 Payment Required`** — ARC rejected the broadcast (malformed tx, insufficient funds, double-spend). This is a client fault.
- **`503 Service Unavailable`** — ARC is unreachable, timing out, or returning 5xx. This is an infrastructure fault; the payment may be legitimate but cannot be settled.

**ARC is a hard runtime dependency in the critical path.** Operators should monitor ARC reachability and latency the same way they monitor their own database. If ARC is down, x402-rack cannot settle payments — no broadcast, no content. There is no kill-switch: vendor-broadcast is not optional, because without it there is no meaningful enforcement. For dev/staging flows, mock the gateway or avoid enabling payment middleware on un-gated routes.

## Installation

```ruby
# Gemfile
gem "x402-rack"
```

```bash
bundle install
```

## Quick start

### Minimal: relay to an existing wallet

The simplest setup — no keys, no local wallet, no ARC configuration. Point `operator_wallet_url` at an existing `@bsv/simple` server wallet and PayGateway is auto-enabled:

```ruby
X402.configure do |c|
  c.domain = "api.example.com"
  c.operator_wallet_url = "https://my-wallet.example.com/api/server-wallet"
  c.protect method: :GET, path: "/api/data", amount_sats: 100
end

use X402::Middleware
```

ARC defaults to ARCADE. The server holds no private keys — it derives unique payment addresses from the remote wallet's public key, broadcasts via ARC, then relays the settlement to the wallet for UTXO tracking.

### With a local wallet (enables BRC-121)

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
X402.configure do |c|
  c.domain = "api.example.com"
  c.wallet = X402::Wallet.load
  c.protect method: :GET, path: "/api/data", amount_sats: 100
end

use X402::Middleware
```

Both PayGateway and BRC121Gateway are auto-enabled. ARC defaults to ARCADE.

### With a remote wallet for all gateways

`RemoteWallet` implements the same duck-typed interface as the local wallet, so all gateways work with it — PayGateway, BRC-121, and BRC-105:

```ruby
X402.configure do |c|
  c.domain = "api.example.com"
  c.wallet = X402::RemoteWallet.new(url: "https://my-wallet.example.com/api/server-wallet")
  c.protect method: :GET, path: "/api/data", amount_sats: 100
end

use X402::Middleware
```

With `wallet:` set and no explicit `enable` calls, gateways are auto-wired:

- **`PayGateway`** — works with or without a wallet (the only gateway that does). Without a wallet, it uses `operator_wallet_url` for keyless relay. With a wallet, it uses `internalize_action` for settlement — converging with BRC-121's approach.
- **`BRC121Gateway`** — always enabled when `wallet:` is set. Requires a wallet (local or remote).
- **`BRC105Gateway`** — opt-in via `config.enable :brc105_gateway`. Requires a wallet.

Clients can pay using whichever protocol they support; the middleware dispatches on proof header.

## Gateways

| Gateway | Wallet required? | Setup required | Status |
|---------|-----------------|----------------|--------|
| `PayGateway` (Coinbase v2) | No — works with `operator_wallet_url` alone | Auto-enabled | Stable |
| `BRC121Gateway` (BRC-121) | Yes (local or remote) | Auto-enabled when `wallet:` set | Stable |
| `BRC105Gateway` (BRC-105) | Yes (local or remote) | `config.enable :brc105_gateway` | Transitional |
| `ProofGateway` (merkleworks) | No | `config.enable :proof_gateway` | Experimental |

PayGateway is the only gateway that works without a wallet — it derives payment addresses from the operator's public key and relays settlement after broadcast. BRC-121 and BRC-105 require a wallet for `internalize_action`. ARC defaults to ARCADE when no explicit `arc_url` is configured.

## Advanced configuration

### Explicit gateway enablement

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.wallet = X402::Wallet.load

  config.enable :pay_gateway                           # explicit, same as default
  config.enable :brc105_gateway                        # opt in to BRC-105
  config.enable :proof_gateway, nonce_provider: my_np  # opt in to ProofGateway
end
```

If any `config.enable` calls are made, the auto-enable is skipped — you get exactly what you asked for.

### Per-gateway overrides

```ruby
config.enable :pay_gateway, arc_client: my_custom_arc  # override ARC broadcaster
config.enable :brc121_gateway, wallet: alt_wallet      # override wallet
```

### Manual gateway construction (power-user escape hatch)

```ruby
X402.configure do |config|
  config.domain = "api.example.com"
  config.gateways = [
    X402::BSV::PayGateway.new(
      arc_client: BSV::Network::ARC.default,
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

- **BSV-pay** (Coinbase v2 headers) — server broadcasts via ARC (defaults to ARCADE). Partial transaction template, unique derived addresses per payment. Works without a wallet via `operator_wallet_url`.
- **BRC-121** (BSV Association simple) — stateless, BRC-100 wallet-native, zero config.
- **BRC-105** (BSV Association authenticated) — settlement via `wallet.internalize_action`. Transitional; requires BRC-103 for spec compliance.
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
