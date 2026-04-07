# frozen_string_literal: true

# Feature spec: bsv-x402 extension wallet setup and unlock.
#
# Smoke test for the Phase 3 browser integration infrastructure. Verifies
# that Capybara can drive Chrome with the bsv-x402 extension side-loaded,
# create a new wallet via the setup page, and unlock it via the popup.
# No x402 payment flow is exercised here — that's a later phase.

require_relative "feature_helper"

RSpec.feature "bsv-x402 wallet setup and unlock", type: :feature do
  scenario "creates a wallet and unlocks it with the password" do
    # Wake up the extension content script by visiting a server page.
    visit "/"
    expect(page).to have_content("root")

    # Drive the setup page: create new wallet, set password, complete.
    visit extension_url("ui/wallet/setup.html")

    expect(page).to have_no_content("Generating...", wait: 5)

    fill_in "password", with: FeatureHelper::WALLET_PASSWORD
    fill_in "password-confirm", with: FeatureHelper::WALLET_PASSWORD
    click_button "Complete Setup"

    expect(page).to have_css("#success-overlay.visible", wait: 5)

    # Open the popup — wallet is auto-unlocked immediately after setup.
    visit extension_url("ui/popup.html")
    expect(page).to have_css("#status-indicator", text: "Unlocked", wait: 5)

    # Lock it so we can exercise the unlock flow.
    click_button "Lock"
    expect(page).to have_css("#status-indicator", text: "Locked", wait: 5)

    # The popup auto-reveals the unlock form in locked state.
    fill_in "unlock-password", with: FeatureHelper::WALLET_PASSWORD
    click_button "Unlock"

    # Verify unlocked state: status flips and balance renders as a
    # concrete value ("0 sats"), not the placeholder ("--- sats").
    expect(page).to have_css("#status-indicator", text: "Unlocked", wait: 5)
    expect(page).to have_css("#balance-display", text: "0 sats")
    expect(page).to have_no_css("#balance-display", text: "--- sats")
  end
end
