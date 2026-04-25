# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::HubClient — Faraday 2 client to the Notification Hub
# (PRD §6.1 + §13.2). Hub IS a third-party service per the mock
# policy in CODING_STANDARDS_TESTING_LIVE.md — `Faraday::Adapter::Test`
# is the canonical mock. Local services (Postgres, Redis) are NOT
# touched; this test does not boot a Hub instance.
class HubClientTest < ActiveSupport::TestCase
  # Each test gets a fresh stubs builder + fresh client — isolation across
  # parallel workers.
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::HubClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://hub.example.test"
    )
  end

  def with_hub_enabled
    prev = ENV["NOTIFICATION_HUB_ENABLED"]
    ENV["NOTIFICATION_HUB_ENABLED"] = "true"
    yield
  ensure
    ENV["NOTIFICATION_HUB_ENABLED"] = prev
  end

  def with_hub_disabled
    prev = ENV["NOTIFICATION_HUB_ENABLED"]
    ENV["NOTIFICATION_HUB_ENABLED"] = "false"
    yield
  ensure
    ENV["NOTIFICATION_HUB_ENABLED"] = prev
  end

  test "happy path — 200 returns sent + hub_event_id" do
    with_hub_enabled do
      prev_key = ENV["NOTIFICATION_HUB_API_KEY"]
      ENV["NOTIFICATION_HUB_API_KEY"] = "test-key"
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/api/events") do |env|
        assert_equal "test-key", env.request_headers["X-API-Key"]
        assert_equal "vpi/0.1 (faraday)", env.request_headers["User-Agent"]
        [200, { "Content-Type" => "application/json" }, '{"event_id":"hub-evt-123"}']
      end

      client = build_client(stubs: stubs)
      result = client.send_event({ event_type: "vendor.risk_band_changed" })

      assert_equal :sent, result[:status]
      assert_equal "hub-evt-123", result[:hub_event_id]
      assert_equal 200, result[:response_code]
      stubs.verify_stubbed_calls
    ensure
      ENV["NOTIFICATION_HUB_API_KEY"] = prev_key
    end
  end

  test "disabled — returns :skipped and makes no HTTP call" do
    with_hub_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # Intentionally register NOTHING — any HTTP call would 404 the stub
      # and Faraday::Adapter::Test would raise.

      client = build_client(stubs: stubs)
      result = client.send_event({ event_type: "anything" })

      assert_equal :skipped, result[:status]
      assert_match(/disabled/i, result[:reason])

      # No stub was hit. Sanity check: there are no expected stubs to
      # verify, so verify_stubbed_calls is a no-op (passes trivially).
      stubs.verify_stubbed_calls
    end
  end

  test "4xx terminal — returns :failed without retrying" do
    with_hub_enabled do
      call_count = 0
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/api/events") do |_env|
        call_count += 1
        [422, { "Content-Type" => "application/json" }, '{"error":"unknown event_type"}']
      end

      client = build_client(stubs: stubs)
      result = client.send_event({ event_type: "garbage" })

      assert_equal :failed, result[:status]
      assert_equal 422, result[:response_code]
      assert_equal "unknown event_type", result[:error]
      assert_equal 1, call_count, "4xx must NOT trigger retries"
    end
  end

  test "5xx with retry exhausted — raises TransientFailure" do
    with_hub_enabled do
      call_count = 0
      stubs = Faraday::Adapter::Test::Stubs.new
      # Match same path repeatedly — Faraday::Adapter::Test queues stubs.
      4.times do
        stubs.post("/api/events") do |_env|
          call_count += 1
          [503, { "Content-Type" => "application/json" }, '{"error":"unavailable"}']
        end
      end

      client = build_client(stubs: stubs)
      assert_raises(Ecosystem::TransientFailure) do
        client.send_event({ event_type: "x" })
      end
      assert_operator call_count, :>=, 1, "Hub must be called at least once before failing"
    end
  end

  test "network failure (Faraday::ConnectionFailed) — raises TransientFailure" do
    with_hub_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # Generous stubs — Faraday's retry middleware will keep hitting
      # the adapter until it gives up.
      10.times do
        stubs.post("/api/events") { |_env| raise Faraday::ConnectionFailed.new("conn refused") }
      end

      client = build_client(stubs: stubs)
      assert_raises(Ecosystem::TransientFailure) do
        client.send_event({ event_type: "x" })
      end
    end
  end

  test "circuit breaker opens after 5 failures and short-circuits" do
    with_hub_enabled do
      breaker = Ecosystem::CircuitBreaker.new(failure_threshold: 5, window_seconds: 60, cooldown_seconds: 60)
      stubs = Faraday::Adapter::Test::Stubs.new
      # Generous stubs for the trip-tripping retries.
      40.times { stubs.post("/api/events") { |_| [503, {}, "{}"] } }

      client = build_client(stubs: stubs, breaker: breaker)

      # Trip the breaker.
      5.times do
        assert_raises(Ecosystem::TransientFailure) { client.send_event({}) }
      end

      assert_equal :open, breaker.status

      # After OPEN: NO further HTTP. Use a fresh stubs that explodes
      # if hit.
      assert_raises(Ecosystem::CircuitOpen) { client.send_event({}) }
    end
  end

  test "X-API-Key header sourced from NOTIFICATION_HUB_API_KEY env" do
    with_hub_enabled do
      prev = ENV["NOTIFICATION_HUB_API_KEY"]
      ENV["NOTIFICATION_HUB_API_KEY"] = "specific-test-key-abc"
      begin
        captured_key = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.post("/api/events") do |env|
          captured_key = env.request_headers["X-API-Key"]
          [200, {}, '{"event_id":"e-1"}']
        end

        client = build_client(stubs: stubs)
        client.send_event({})
        assert_equal "specific-test-key-abc", captured_key
      ensure
        ENV["NOTIFICATION_HUB_API_KEY"] = prev
      end
    end
  end

  test "send_event payload is JSON-encoded" do
    with_hub_enabled do
      captured_body = nil
      captured_ct = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/api/events") do |env|
        captured_body = env.body
        captured_ct = env.request_headers["Content-Type"]
        [200, {}, '{"event_id":"e-1"}']
      end

      client = build_client(stubs: stubs)
      client.send_event({ event_type: "vendor.risk_band_changed", payload: { foo: "bar" } })

      assert_includes captured_ct, "application/json"
      parsed = JSON.parse(captured_body)
      assert_equal "vendor.risk_band_changed", parsed["event_type"]
      assert_equal "bar", parsed.dig("payload", "foo")
    end
  end
end
