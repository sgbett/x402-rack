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
      arc_client: BSV::Network::ARC.new("https://arcade.gorillapool.io", api_key: "..."),
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
  "https://arcade.gorillapool.io",
  api_key: "your-api-key"
)
```

- **Testnet**: `https://testnet.arcade.gorillapool.io`
- **Mainnet**: `https://arcade.gorillapool.io`

### ARC is a hard dependency

`BRC121Gateway` and `BRC105Gateway` enforce the NO PAY → NO CONTENT invariant by broadcasting the client's signed BEEF to ARC themselves before mutating wallet state. `ProofGateway` reads ARC status (the scheme is explicitly proof-of-prior-payment). Either way, **ARC reachability is a hard runtime dependency on the critical path** — treat it with the same seriousness as your primary database. This was true before vendor-broadcast and it is even more true now: without a successful ARC broadcast there is literally no settlement.

Minimum monitoring:

- **Reachability** — alert on elevated 5xx rate or connection failures from the configured ARC host(s)
- **Latency** — broadcast calls block the client-facing response; if ARC median latency grows, paid-endpoint latency grows in step
- **Status-code mix in x402-rack itself** — elevated **503s** point at an ARC incident; elevated **402s** point at client misbehaviour. The distinction is deliberate and should drive different alert paths:
    - **Lots of 503s** → page the on-call operator; ARC is likely down or degraded. Paid requests are (correctly) being refused until ARC recovers.
    - **Lots of 402s** → investigate the client. Common causes: malformed BEEF, insufficient funds on client-provided inputs, or an attempted double-spend.

### No kill-switch

There is no `verify_on_chain` toggle. Vendor-broadcast is not optional — without it there is no meaningful enforcement of NO PAY → NO CONTENT, and a "partial enforcement" mode would be worse than either extreme (it would give the wrong impression of safety). Earlier releases (0.10.x) shipped a kill-switch; 0.11.0 removes it.

For dev or staging environments that don't want real payments: mock the gateway, or don't enable payment middleware on the routes you want un-gated. `config.protect` is opt-in per-route — the simplest solution is usually not to protect the route at all in development.

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
| `ARC_API_KEY` | Optional | ARCADE API key (if required by provider) |
| `PAYEE_SCRIPT` | Yes | Payee locking script hex |
