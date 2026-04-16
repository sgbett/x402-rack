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

Every gateway enforces the NO PAY → NO CONTENT invariant by asking ARC whether the payment transaction is visible on the network before mutating wallet state. **ARC reachability is therefore a hard runtime dependency on the critical path** — treat it with the same seriousness as your primary database.

Minimum monitoring:

- **Reachability** — alert on elevated 5xx rate or connection failures from the configured ARC host(s)
- **Latency** — verification retries span ~1.75 s worst case; if ARC median latency approaches that, users will see timeouts
- **Status-code mix in x402-rack itself** — elevated **503s** point at an ARC incident; elevated **402s** point at client misbehaviour or exploit attempts. The distinction is deliberate and should drive different alert paths:
    - **Lots of 503s** → page the on-call operator; ARC is likely down or degraded. Paid requests are (correctly) being refused until ARC recovers.
    - **Lots of 402s** → investigate the client. Common causes: wallets misconfigured with `no_send: true` without subsequent broadcast, pointing at a different ARC than the server, or an attempted `no_send` exploit.

### Kill-switch: `verify_on_chain`

Some development and staging environments run test suites against wallets that never broadcast (mocks, fixtures, local-only flows). Rather than monkey-patching the gateway, disable the on-chain check explicitly:

```ruby
X402.configure do |c|
  c.verify_on_chain = false
  # ...
end
```

Or via environment variable (useful for per-environment containers):

```bash
X402_VERIFY_ON_CHAIN=false
```

Accepted falsy values (case-insensitive, whitespace-trimmed): `false`, `0`, `no`. Any other value — including unset — keeps the safe default of `true`.

When disabled, x402-rack emits a loud WARN banner at startup so the override cannot be missed:

```
[x402] verify_on_chain is disabled — NO PAY → NO CONTENT is NOT enforced. Do not run in production.
```

The default is `true` for a reason. Do not disable it in production.

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
