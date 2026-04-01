# Deployment

## Configuration

```ruby
# config.ru or Rails initialiser
require "x402"
require "x402/bsv"

X402.configure do |config|
  config.domain = "api.example.com"
  config.payee_locking_script_hex = "76a914...88ac"

  config.gateways = [
    X402::BSV::PayGateway.new(
      arc_client: BSV::Network::ARC.new("https://arc.taal.com", api_key: "..."),
      payee_locking_script_hex: "76a914...88ac"
    )
  ]

  config.protect method: :GET, path: "/api/premium", amount_sats: 500
end

use X402::Middleware
```

## ARC Setup

Both gateways need an ARC endpoint. The `bsv-sdk` provides `BSV::Network::ARC`:

```ruby
arc = BSV::Network::ARC.new(
  "https://arc.taal.com",
  api_key: "your-api-key"
)
```

- **Testnet**: `https://arc-test.taal.com`
- **Mainnet**: `https://arc.taal.com`
- **API key**: free for low volume at https://console.taal.com

## Rate Limiting

The middleware itself does not implement rate limiting. The synchronous ARC wait in PayGateway (`X-WaitFor: SEEN_ON_NETWORK`) holds the connection open for up to 5 seconds per request — this is a potential DoS vector under high load.

**Mitigation**: rate limit at the web server level (nginx, Apache) or via Rack middleware (e.g. `Rack::Attack`):

```ruby
# Gemfile
gem "rack-attack"

# config.ru
use Rack::Attack
Rack::Attack.throttle("x402", limit: 60, period: 60) do |req|
  req.ip if req.path.start_with?("/api/")
end

use X402::Middleware
```

This is not the middleware's concern — it's a deployment decision.

## Multiple Gateways

A server can offer multiple payment options simultaneously:

```ruby
config.gateways = [
  X402::BSV::PayGateway.new(arc_client: arc),
  X402::BSV::ProofGateway.new(
    nonce_provider: treasury,
    arc_client: arc
  )
]
```

The 402 response will include headers from both gateways. The client picks whichever it supports.

## Environment Variables

For production, use environment variables for secrets:

```ruby
arc = BSV::Network::ARC.new(
  ENV.fetch("ARC_URL"),
  api_key: ENV["ARC_API_KEY"]
)
```

| Variable | Required | Description |
|----------|----------|-------------|
| `ARC_URL` | Yes | ARC broadcast endpoint |
| `ARC_API_KEY` | TAAL requires it | TAAL ARC API key |
| `PAYEE_SCRIPT` | Yes | Payee locking script hex |
