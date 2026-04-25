# frozen_string_literal: true

require "test_helper"
require_relative "../../../support/vcr_setup"

# VCR cassette test for Ecosystem::HubClient — PRD §13.2 + §12 #12.
#
# Replays a recorded happy-path request/response pair against the real
# Faraday stack (no test adapter). This proves the URL, headers, retry,
# and response parsing wiring works end-to-end without needing a live
# Hub deployment in CI.
class HubClientCassetteTest < ActiveSupport::TestCase
  parallelize(workers: 1)

  setup do
    @prev_enabled = ENV["NOTIFICATION_HUB_ENABLED"]
    @prev_url     = ENV["NOTIFICATION_HUB_URL"]
    @prev_key     = ENV["NOTIFICATION_HUB_API_KEY"]
    ENV["NOTIFICATION_HUB_ENABLED"] = "true"
    ENV["NOTIFICATION_HUB_URL"]     = "http://hub.example.test"
    ENV["NOTIFICATION_HUB_API_KEY"] = "[FILTERED_API_KEY]"
  end

  teardown do
    ENV["NOTIFICATION_HUB_ENABLED"] = @prev_enabled
    ENV["NOTIFICATION_HUB_URL"]     = @prev_url
    ENV["NOTIFICATION_HUB_API_KEY"] = @prev_key
  end

  test "send_event replays cassette → returns :sent + parses event_id" do
    client = Ecosystem::HubClient.new

    VCR.use_cassette("hub_client/send_event") do
      result = client.send_event({
        event_type: "vendor.risk_band_changed",
        alert_id: "alrt-123",
        tenant: { slug: "acme" }
      })

      assert_equal :sent, result[:status]
      assert_equal "hub-evt-cassette-001", result[:hub_event_id]
      assert_equal 200, result[:response_code]
    end
  end
end
