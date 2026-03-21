# x402-rack

Rack middleware implementing the [x402 protocol](https://x402.merkleworks.io/) — stateless, settlement-gated HTTP using BSV (Bitcoin SV).

Clients requesting protected routes receive a `402 Payment Required` response with an `X402-Challenge` header. They construct a BSV payment transaction, broadcast it, and retry with proof. The middleware verifies the proof and forwards valid requests to your application.

## Status

Early development (v0.1.0). The protocol layer is implemented; the BSV backend (`X402::BSV`) is in progress. See [DESIGN.md](DESIGN.md) for architecture notes.

**This is pre-release software and should not be used for real-world monetary purposes.**

## Installation

Add to your Gemfile:

```ruby
gem "x402-rack", git: "https://github.com/sgbett/x402-rack.git"
```

## Usage

```ruby
# config.ru or Rails initializer
require "x402"

X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"
  config.nonce_provider = ->(request) { fetch_nonce_from_wallet(request) }

  config.protect method: :GET, path: "/api/expensive", amount_sats: 100
end

use X402::Middleware
```

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
