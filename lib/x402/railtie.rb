# frozen_string_literal: true

module X402
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("../tasks/x402.rake", __dir__)
    end
  end
end
