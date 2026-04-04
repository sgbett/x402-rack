# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

x402-rack is a Ruby gem providing Rack middleware for the x402 protocol (BSV settlement-gated HTTP). Requires Ruby >= 3.1.

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

## Specifications

This project implements published protocol specifications (BRC-105, BRC-29, etc.). When writing or modifying code that implements a spec, consult the spec directly (via `bsv-protocol-docs` MCP) and verify conformance — including optional features unless there is a documented reason to omit them. Tests should be anchored to spec requirements, not just implementation behaviour.

## Code Style

- Double quotes for strings (enforced by RuboCop)
- `frozen_string_literal: true` magic comment on all Ruby files
- Target Ruby version: 3.1
