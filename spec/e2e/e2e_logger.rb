# frozen_string_literal: true

require "fileutils"

# Pretty logging for e2e test output.
# Writes to stdout and optionally to a timestamped markdown log file.

module E2ELogger
  ACTORS = {
    treasury: "💰 Treasury",
    client: "🌐 Client",
    server: "🖥  Server",
    arc: "⛏  ARC",
    delegator: "🤝 Delegator"
  }.freeze

  class << self
    attr_accessor :log_file

    def start_log(name)
      dir = File.expand_path("logs", __dir__)
      FileUtils.mkdir_p(dir)
      timestamp = Time.now.strftime("%Y-%m-%d-%H%M%S")
      path = File.join(dir, "#{name}-#{timestamp}.md")
      self.log_file = File.new(path, "w") # -- intentionally held open, closed in finish_log
      log_file.puts "# #{name} — #{Time.now.strftime("%Y-%m-%d %H:%M:%S")}"
      log_file.puts "```"
      path
    end

    def finish_log
      return unless log_file

      log_file.puts "```"
      log_file.close
      self.log_file = nil
    end

    def emit(line)
      $stdout.puts line
      log_file&.puts(line)
    end

    def header(title)
      emit ""
      emit "┌#{"─" * 78}┐"
      emit "│ #{title.ljust(77)}│"
      emit "└#{"─" * 78}┘"
      emit ""
    end

    def step(number, actor, action, detail = nil)
      timestamp = Time.now.strftime("%H:%M:%S.%L")
      actor_label = ACTORS.fetch(actor, actor.to_s)
      emit "  #{timestamp}  [#{number}] #{actor_label} → #{action}"
      emit "               #{detail}" if detail
    end

    def arrow(from, to, message)
      from_label = ACTORS.fetch(from, from.to_s)
      to_label = ACTORS.fetch(to, to.to_s)
      timestamp = Time.now.strftime("%H:%M:%S.%L")
      emit "  #{timestamp}       #{from_label}  ──▶  #{to_label}"
      emit "                     #{message}"
    end

    def result(label, value)
      emit "               #{label}: #{value}"
    end

    def tx(label, txid, network: :testnet)
      short = txid[0..15]
      base = network == :testnet ? "https://test.whatsonchain.com" : "https://whatsonchain.com"
      emit "               #{label}: #{short}..."
      emit "               #{base}/tx/#{txid}"
    end

    def wallet(role, address, network: :testnet)
      base = network == :testnet ? "https://test.whatsonchain.com" : "https://whatsonchain.com"
      emit "  #{ACTORS.fetch(role, role.to_s).ljust(20)} #{address}"
      emit "  #{" " * 20} #{base}/address/#{address}"
    end

    def wallets(treasury_addr: nil, client_addr: nil, payee_script: nil)
      emit ""
      emit "  Wallets:"
      wallet(:treasury, treasury_addr) if treasury_addr
      wallet(:client, client_addr) if client_addr
      emit "  💳 Payee               #{payee_script}" if payee_script
      emit ""
    end

    def separator
      emit "  #{"─" * 74}"
    end

    def success(message)
      emit ""
      emit "  ✅ #{message}"
      emit ""
    end

    def failure(message)
      emit ""
      emit "  ❌ #{message}"
      emit ""
    end
  end
end
