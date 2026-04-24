require "test_helper"
require "capybara/playwright"

# System test harness — drives Rails via Capybara + Playwright (headless Chromium).
#
# The Chromium binary lives in the `playwright_cache` named volume (mounted at
# /home/rails/.cache/ms-playwright), installed once via
# `bin/dc bash -c "npx playwright install chromium"`. System deps for Chromium
# were pre-baked into docker/Dockerfile.dev in Batch 001.
#
# Replaces the Rails 8 default Selenium-driven case (PRD §3 calls for Playwright,
# not Selenium — PRD-flagged for Turbo Streams coverage).
Capybara.register_driver(:playwright) do |app|
  Capybara::Playwright::Driver.new(app, browser_type: :chromium, headless: true)
end

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :playwright

  # Silent Puma avoids flooding the test output with request logs for every
  # system-test visit. The default test database config still applies.
  Capybara.server = :puma, { Silent: true }
  Capybara.default_max_wait_time = 5
end
