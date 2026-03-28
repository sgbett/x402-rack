# frozen_string_literal: true

# Pretty logging for e2e test output.
# Shows the flow of actors, actions, and on-chain artefacts.

module E2ELogger
  ACTORS = {
    treasury: "💰 Treasury",
    client: "🌐 Client",
    server: "🖥  Server",
    arc: "⛏  ARC",
    delegator: "🤝 Delegator"
  }.freeze

  class << self
    def header(title)
      puts ""
      puts "┌#{"─" * 78}┐"
      puts "│ #{title.ljust(77)}│"
      puts "└#{"─" * 78}┘"
      puts ""
    end

    def step(number, actor, action, detail = nil)
      timestamp = Time.now.strftime("%H:%M:%S.%L")
      actor_label = ACTORS.fetch(actor, actor.to_s)
      line = "  #{timestamp}  [#{number}] #{actor_label} → #{action}"
      puts line
      puts "               #{detail}" if detail
    end

    def arrow(from, to, message)
      from_label = ACTORS.fetch(from, from.to_s)
      to_label = ACTORS.fetch(to, to.to_s)
      timestamp = Time.now.strftime("%H:%M:%S.%L")
      puts "  #{timestamp}       #{from_label}  ──▶  #{to_label}"
      puts "                     #{message}"
    end

    def result(label, value)
      puts "               #{label}: #{value}"
    end

    def tx(label, txid, network: :testnet)
      short = txid[0..15]
      base = network == :testnet ? "https://test.whatsonchain.com" : "https://whatsonchain.com"
      puts "               #{label}: #{short}..."
      puts "               #{base}/tx/#{txid}"
    end

    def wallet(role, address, network: :testnet)
      base = network == :testnet ? "https://test.whatsonchain.com" : "https://whatsonchain.com"
      puts "  #{ACTORS.fetch(role, role.to_s).ljust(20)} #{address}"
      puts "  #{" " * 20} #{base}/address/#{address}"
    end

    def wallets(treasury_addr: nil, client_addr: nil, payee_script: nil)
      puts ""
      puts "  Wallets:"
      wallet(:treasury, treasury_addr) if treasury_addr
      wallet(:client, client_addr) if client_addr
      puts "  💳 Payee               #{payee_script}" if payee_script
      puts ""
    end

    def separator
      puts "  #{"─" * 74}"
    end

    def success(message)
      puts ""
      puts "  ✅ #{message}"
      puts ""
    end

    def failure(message)
      puts ""
      puts "  ❌ #{message}"
      puts ""
    end
  end
end
