# frozen_string_literal: true

# Feature spec helper for browser-driven tests of the bsv-x402
# Chromium extension against an x402-rack server.
#
# These specs sit between unit/integration specs (no network, real SDK
# objects) and e2e specs (real testnet + ARC). They drive a real Chrome
# browser with the bsv-x402 extension side-loaded, talking to a Rack app
# served in-process via Capybara's built-in server.
#
# Excluded from default +bundle exec rake+. Run with:
#
#   bundle install --with feature
#   bundle exec rake feature
#
# Set +BSV_X402_EXTENSION_PATH+ to override the default extension build
# location. Set +HEADED=1+ to launch Chrome in headed mode.

require "capybara/rspec"
require "selenium-webdriver"
require "rack"
require "securerandom"
require "bsv-sdk"
require "x402"

module FeatureHelper
  EXTENSION_PATH = ENV.fetch("BSV_X402_EXTENSION_PATH", "/opt/js/bsv-x402/dist/plugins/chromium")
  WALLET_PASSWORD = "correcthorsebatterystaple"

  # Chrome stable (Google Chrome 137+) silently drops --load-extension.
  # Feature specs require Chrome for Testing, installed via:
  #   npx @puppeteer/browsers install chrome@stable \
  #     --path=$HOME/.cache/chrome-for-testing
  CFT_ROOT = File.expand_path("~/.cache/chrome-for-testing")
  CHROME_GLOB = "chrome/*/chrome-mac-arm64/Google Chrome for Testing.app" \
                "/Contents/MacOS/Google Chrome for Testing"
  CHROMEDRIVER_GLOB = "chromedriver/*/chromedriver-mac-arm64/chromedriver"

  CHROME_BIN = ENV.fetch(
    "BSV_X402_CHROME_BIN",
    Dir.glob(File.join(CFT_ROOT, CHROME_GLOB)).max.to_s
  )
  CHROMEDRIVER_BIN = ENV.fetch(
    "BSV_X402_CHROMEDRIVER_BIN",
    Dir.glob(File.join(CFT_ROOT, CHROMEDRIVER_GLOB)).max.to_s
  )

  # Test-only WIF — generated at load time, never funded.
  TEST_SERVER_WIF = BSV::Primitives::PrivateKey.generate.to_wif

  def self.extension_available?
    File.directory?(EXTENSION_PATH) && File.exist?(File.join(EXTENSION_PATH, "manifest.json"))
  end

  def self.chrome_for_testing_available?
    !CHROME_BIN.empty? && File.executable?(CHROME_BIN)
  end

  # Build a minimal Rack app with X402::Middleware mounted. The root
  # handler returns a trivial page so the browser has something to
  # visit as a wake-up for the extension content script.
  def self.build_rack_app
    X402.reset_configuration!
    X402.configure do |c|
      c.domain = "test.local"
      c.server_wif = TEST_SERVER_WIF
      c.arc_url = "http://localhost:9999"
      c.enable :pay_gateway, challenge_secret: "a" * 32
      c.protect method: :GET, path: "/premium", amount_sats: 100
      c.enable_status_endpoint
      c.status_endpoint_token = "test-feature-token"
    end

    middleware = X402::Middleware
    Rack::Builder.new do
      use middleware
      run ->(_env) { [200, { "content-type" => "text/html" }, ["<html><body>root</body></html>"]] }
    end.to_app
  end

  # Resolve the bsv-x402 extension ID by querying CDP for targets and
  # matching a chrome-extension://... URL. Memoised per-session.
  # The default +Target.getTargets+ call omits service workers, so we
  # pass an explicit filter that includes them.
  def extension_id
    @extension_id ||= begin
      targets = page.driver.browser.execute_cdp(
        "Target.getTargets",
        filter: [
          { type: "service_worker" },
          { type: "background_page" },
          { type: "page" },
          { type: "tab" },
          { type: "other" }
        ]
      )
      entries = targets["targetInfos"] || []
      match = entries
              .map { |t| t["url"].to_s }
              .grep(%r{\Achrome-extension://([a-p]{32})/}) { Regexp.last_match(1) }
              .first
      raise "Could not resolve bsv-x402 extension ID from CDP targets" unless match

      match
    end
  end

  def extension_url(path)
    "chrome-extension://#{extension_id}/#{path}"
  end
end

Capybara.register_driver :chrome_x402 do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.binary = FeatureHelper::CHROME_BIN unless FeatureHelper::CHROME_BIN.empty?
  options.add_argument("--load-extension=#{FeatureHelper::EXTENSION_PATH}")
  options.add_argument("--disable-extensions-except=#{FeatureHelper::EXTENSION_PATH}")
  options.add_argument("--headless=new") unless ENV["HEADED"]
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--window-size=1280,800")
  service = Selenium::WebDriver::Service.chrome
  service.executable_path = FeatureHelper::CHROMEDRIVER_BIN unless FeatureHelper::CHROMEDRIVER_BIN.empty?

  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options, service: service)
end

Capybara.server = :webrick
Capybara.app = FeatureHelper.build_rack_app
Capybara.default_driver = :chrome_x402
Capybara.javascript_driver = :chrome_x402
Capybara.default_max_wait_time = 10

RSpec.configure do |config|
  config.include FeatureHelper, type: :feature

  config.before(:each, type: :feature) do
    skip "bsv-x402 extension not found at #{FeatureHelper::EXTENSION_PATH}" unless FeatureHelper.extension_available?
    unless FeatureHelper.chrome_for_testing_available?
      skip "Chrome for Testing not installed — run `npx @puppeteer/browsers " \
           "install chrome@stable --path=$HOME/.cache/chrome-for-testing`"
    end
  end
end
