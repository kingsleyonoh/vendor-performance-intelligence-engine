# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::WebhookEngineClient — Faraday 2 client to the Webhook Ingestion
# Engine (PRD §6 + §13.2). Mirrors HubClient/WorkflowClient. The Webhook
# Engine is a third-party service per the mock policy in
# CODING_STANDARDS_TESTING_LIVE.md — `Faraday::Adapter::Test` is canonical.
class WebhookEngineClientTest < ActiveSupport::TestCase
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::WebhookEngineClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://webhook-engine.example.test"
    )
  end

  def with_enabled
    prev = ENV["WEBHOOK_ENGINE_ENABLED"]
    ENV["WEBHOOK_ENGINE_ENABLED"] = "true"
    yield
  ensure
    ENV["WEBHOOK_ENGINE_ENABLED"] = prev
  end

  def with_disabled
    prev = ENV["WEBHOOK_ENGINE_ENABLED"]
    ENV["WEBHOOK_ENGINE_ENABLED"] = "false"
    yield
  ensure
    ENV["WEBHOOK_ENGINE_ENABLED"] = prev
  end

  test "list_sources happy path returns array" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/sources") do |env|
        assert env.request_headers["X-API-Key"].present?
        [200, { "Content-Type" => "application/json" },
         '{"sources":[{"id":"src-1","name":"acme-source","status":"active"}]}']
      end

      client = build_client(stubs: stubs)
      result = client.list_sources

      assert_equal :ok, result[:status]
      assert_equal 1, result[:sources].length
      assert_equal "src-1", result[:sources].first["id"]
      stubs.verify_stubbed_calls
    end
  end

  test "list_dead_letters happy path returns paginated payload" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/dead-letters") do |env|
        assert_includes env.url.query.to_s, "since="
        [200, {}, '{"dead_letters":[{"id":"dl-1","payload":{}}],"page":1,"total":1}']
      end

      client = build_client(stubs: stubs)
      result = client.list_dead_letters(since: "2026-04-01T00:00:00Z", page: 1)

      assert_equal :ok, result[:status]
      assert_equal 1, result[:dead_letters].length
      assert_equal 1, result[:page]
    end
  end

  test "fetch_stats happy path returns rate fields" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/stats") do |env|
        body = '{"success_rate_24h":0.97,"dead_letter_count_24h":3,' \
               '"schema_drift_24h":1,"retry_avg_24h":0.5}'
        [200, {}, body]
      end

      client = build_client(stubs: stubs)
      result = client.fetch_stats

      assert_equal :ok, result[:status]
      assert_in_delta 0.97, result[:stats]["success_rate_24h"], 1e-6
      assert_equal 3, result[:stats]["dead_letter_count_24h"]
    end
  end

  test "disabled — returns :skipped without HTTP" do
    with_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # No stubs registered — any HTTP call would blow up.

      client = build_client(stubs: stubs)
      list_res  = client.list_sources
      dl_res    = client.list_dead_letters
      stats_res = client.fetch_stats

      [list_res, dl_res, stats_res].each do |r|
        assert_equal :skipped, r[:status]
        assert_match(/disabled/i, r[:reason])
      end
    end
  end

  test "4xx terminal — returns :failed without retrying" do
    with_enabled do
      call_count = 0
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/stats") do |_env|
        call_count += 1
        [401, {}, '{"error":"bad api key"}']
      end

      client = build_client(stubs: stubs)
      result = client.fetch_stats

      assert_equal :failed, result[:status]
      assert_equal 401, result[:response_code]
      assert_equal 1, call_count, "4xx must not retry"
    end
  end

  test "5xx with retry exhausted — raises TransientFailure" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      6.times do
        stubs.get("/api/stats") { |_| [503, {}, '{"error":"unavailable"}'] }
      end

      client = build_client(stubs: stubs)
      assert_raises(Ecosystem::TransientFailure) { client.fetch_stats }
    end
  end

  test "circuit breaker opens after 5 failures and short-circuits" do
    with_enabled do
      breaker = Ecosystem::CircuitBreaker.new(failure_threshold: 5,
                                              window_seconds: 60,
                                              cooldown_seconds: 60)
      stubs = Faraday::Adapter::Test::Stubs.new
      40.times { stubs.get("/api/stats") { |_| [503, {}, "{}"] } }

      client = build_client(stubs: stubs, breaker: breaker)
      5.times { assert_raises(Ecosystem::TransientFailure) { client.fetch_stats } }

      assert_equal :open, breaker.status
      assert_raises(Ecosystem::CircuitOpen) { client.fetch_stats }
    end
  end

  test "X-API-Key header sourced from WEBHOOK_ENGINE_API_KEY env" do
    with_enabled do
      prev = ENV["WEBHOOK_ENGINE_API_KEY"]
      ENV["WEBHOOK_ENGINE_API_KEY"] = "specific-webhook-key-xyz"
      begin
        captured = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/api/sources") do |env|
          captured = env.request_headers["X-API-Key"]
          [200, {}, '{"sources":[]}']
        end

        client = build_client(stubs: stubs)
        client.list_sources
        assert_equal "specific-webhook-key-xyz", captured
      ensure
        ENV["WEBHOOK_ENGINE_API_KEY"] = prev
      end
    end
  end
end
