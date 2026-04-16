# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

x402-rack is a Ruby gem providing Rack middleware for the x402 protocol (BSV settlement-gated HTTP). Requires Ruby >= 3.1.

The core invariant is **NO PAY → NO CONTENT**: content is served if and only if the payment transaction is visible on the BSV network. Every gateway verifies on-chain visibility via ARC between validation and state mutation. ARC is a hard runtime dependency; non-visible payments return 402, ARC outages return 503. The `config.verify_on_chain` kill-switch defaults to `true` and must stay on in production.

## Commands

```bash
# Install dependencies
bin/setup

# Run tests
bundle exec rake spec

# Run a single test file
bundle exec rspec spec/x402_spec.rb

# Run a single example by line number
bundle exec rspec spec/x402_spec.rb:4

# Lint
bundle exec rubocop

# Lint with auto-fix
bundle exec rubocop -A

# Run all checks (tests + lint) — this is the CI default
bundle exec rake
```

## Testnet credentials

E2E specs (`spec/e2e/**/*.rb`, tagged `:e2e`, excluded from default `rake`) need credentials in `.env` at the repo root. All WIFs listed there **hold spendable testnet funds** — no need to fund them before running specs:

- `ARC_URL` — testnet ARCADE endpoint
- `ARC_API_KEY` — ARC bearer token
- `TREASURY_WIF` — server wallet (used as `SERVER_WIF` where the BRC-105 / BRC-121 e2e specs read that var)
- `CLIENT_WIF` — client wallet
- `DELEGATOR_WIF` — used by proof-gateway delegated flows
- `PAYEE_SCRIPT` — hex locking script for PayGateway e2e

`.env` is gitignored. The e2e specs do not auto-load it — source manually before running:

```bash
set -a; source .env; set +a
# The BRC-105 / BRC-121 specs read SERVER_WIF, which .env exposes as TREASURY_WIF:
export SERVER_WIF="$TREASURY_WIF"
bundle exec rspec spec/e2e/brc121_gateway_e2e_spec.rb --tag e2e
```

## Specifications

This project implements published protocol specifications (BRC-105, BRC-29, etc.). When writing or modifying code that implements a spec, consult the spec directly (via `bsv-protocol-docs` MCP) and verify conformance — including optional features unless there is a documented reason to omit them. Tests should be anchored to spec requirements, not just implementation behaviour.

## Code Style

- Double quotes for strings (enforced by RuboCop)
- `frozen_string_literal: true` magic comment on all Ruby files
- Target Ruby version: 3.1
