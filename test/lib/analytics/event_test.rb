# frozen_string_literal: true

require "test_helper"

# Analytics::Event facade — PRD §10b.
#
# Thin wrapper around posthog-ruby that:
#   1. Short-circuits when POSTHOG_API_KEY or POSTHOG_HOST is unset
#      (standalone-first invariant).
#   2. Captures (event_name, distinct_id, properties) — distinct_id is the
#      tenant_id (or "anonymous" if no tenant context).
#   3. Tags every event with tenant_id, user_id (when present), and any
#      callsite-supplied properties.
#   4. Swallows network failures — never crashes the request.
class AnalyticsEventTest < ActiveSupport::TestCase
  def setup
    @original_key  = ENV["POSTHOG_API_KEY"]
    @original_host = ENV["POSTHOG_HOST"]
  end

  def teardown
    ENV["POSTHOG_API_KEY"] = @original_key
    ENV["POSTHOG_HOST"]    = @original_host
    Analytics::Event.reset!
    Current.tenant = nil
  end

  test "track is a no-op when POSTHOG_API_KEY unset" do
    ENV.delete("POSTHOG_API_KEY")
    ENV["POSTHOG_HOST"] = "https://posthog.example.com"
    Analytics::Event.reset!
    refute Analytics::Event.enabled?
    assert_nil Analytics::Event.track(event: "vendor_viewed", tenant_id: "abc")
  end

  test "track is a no-op when POSTHOG_HOST unset" do
    ENV["POSTHOG_API_KEY"] = "phc_xxx"
    ENV.delete("POSTHOG_HOST")
    Analytics::Event.reset!
    refute Analytics::Event.enabled?
    assert_nil Analytics::Event.track(event: "vendor_viewed", tenant_id: "abc")
  end

  test "track calls underlying client capture when enabled" do
    ENV["POSTHOG_API_KEY"] = "phc_xxx"
    ENV["POSTHOG_HOST"]    = "https://posthog.example.com"
    Analytics::Event.reset!

    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:capture) { |args| captured = args }
    Analytics::Event.instance_variable_set(:@test_client, fake_client)

    Analytics::Event.track(
      event: "vendor_viewed",
      tenant_id: "tenant-uuid-123",
      user_id: "user-456",
      properties: { vendor_id: "vend-1" }
    )

    refute_nil captured
    assert_equal "vendor_viewed", captured[:event]
    assert_equal "tenant-uuid-123", captured[:distinct_id]
    assert_equal "tenant-uuid-123", captured[:properties][:tenant_id]
    assert_equal "user-456", captured[:properties][:user_id]
    assert_equal "vend-1", captured[:properties][:vendor_id]
  ensure
    Analytics::Event.instance_variable_set(:@test_client, nil)
  end

  test "track defaults distinct_id to anonymous when tenant_id missing" do
    ENV["POSTHOG_API_KEY"] = "phc_xxx"
    ENV["POSTHOG_HOST"]    = "https://posthog.example.com"
    Analytics::Event.reset!

    captured = nil
    fake_client = Object.new
    fake_client.define_singleton_method(:capture) { |args| captured = args }
    Analytics::Event.instance_variable_set(:@test_client, fake_client)

    Analytics::Event.track(event: "vendor_viewed")
    assert_equal "anonymous", captured[:distinct_id]
  ensure
    Analytics::Event.instance_variable_set(:@test_client, nil)
  end

  test "track swallows client failures rather than raising" do
    ENV["POSTHOG_API_KEY"] = "phc_xxx"
    ENV["POSTHOG_HOST"]    = "https://posthog.example.com"
    Analytics::Event.reset!

    fake_client = Object.new
    fake_client.define_singleton_method(:capture) { |_args| raise StandardError, "network down" }
    Analytics::Event.instance_variable_set(:@test_client, fake_client)

    assert_nothing_raised do
      Analytics::Event.track(event: "vendor_viewed", tenant_id: "abc")
    end
  ensure
    Analytics::Event.instance_variable_set(:@test_client, nil)
  end
end
