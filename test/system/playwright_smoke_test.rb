require "application_system_test_case"

# Smoke test proving Capybara + Playwright + headless Chromium boot cleanly
# against a real Puma instance. No dashboard exists yet (Phase 1), so we drive
# Rails' default `/up` health endpoint — a minimal green page that returns 200.
#
# This unblocks every future system test (dashboard, vendor detail, alerts
# inbox, scoring rules) without them also needing to validate the harness.
class PlaywrightSmokeTest < ApplicationSystemTestCase
  test "Playwright can load the Rails health endpoint" do
    visit "/up"
    # Rails 8 renders a bare <html><body> page for /up with HTTP 200. We assert
    # on the DOM-level body being present rather than on text, since the
    # endpoint renders an empty green block with no guaranteed copy.
    assert_selector "body", visible: :all
  end
end
