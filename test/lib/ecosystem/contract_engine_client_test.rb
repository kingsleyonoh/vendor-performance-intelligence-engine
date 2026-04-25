# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::ContractEngineClient — Faraday 2 client to the Contract
# Lifecycle Engine (PRD §6 + §13.2). Mirrors HubClient/WorkflowClient/
# WebhookEngineClient/InvoiceReconClient. Per the mock policy in
# CODING_STANDARDS_TESTING_LIVE.md, this is a third-party service so
# `Faraday::Adapter::Test` is canonical.
class ContractEngineClientTest < ActiveSupport::TestCase
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::ContractEngineClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://contract-engine.example.test"
    )
  end

  def with_enabled
    prev = ENV["CONTRACT_ENGINE_ENABLED"]
    ENV["CONTRACT_ENGINE_ENABLED"] = "true"
    yield
  ensure
    ENV["CONTRACT_ENGINE_ENABLED"] = prev
  end

  def with_disabled
    prev = ENV["CONTRACT_ENGINE_ENABLED"]
    ENV["CONTRACT_ENGINE_ENABLED"] = "false"
    yield
  ensure
    ENV["CONTRACT_ENGINE_ENABLED"] = prev
  end

  test "list_obligations happy path returns array" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/obligations") do |env|
        assert env.request_headers["X-API-Key"].present?
        assert_includes env.url.query.to_s, "vendor_ref="
        [200, { "Content-Type" => "application/json" },
         '{"obligations":[{"id":"ob-1","vendor_ref":"v-1","status":"open"}]}']
      end

      client = build_client(stubs: stubs)
      result = client.list_obligations(vendor_ref: "v-1", since: "2026-04-01T00:00:00Z")

      assert_equal :ok, result[:status]
      assert_equal 1, result[:obligations].length
      assert_equal "ob-1", result[:obligations].first["id"]
      stubs.verify_stubbed_calls
    end
  end

  test "list_breaches happy path returns array" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/breaches") do |_env|
        [200, {}, '{"breaches":[{"id":"br-1","obligation_id":"ob-1"}]}']
      end

      client = build_client(stubs: stubs)
      result = client.list_breaches(since: "2026-04-01T00:00:00Z")

      assert_equal :ok, result[:status]
      assert_equal 1, result[:breaches].length
    end
  end

  test "fetch_stats happy path returns ratios + counts" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/stats") do |env|
        assert_includes env.url.query.to_s, "vendor_ref="
        body = '{"renewal_risk_level":2,"sla_miss_ratio_30d":0.18,' \
               '"obligation_breach_count_90d":3,"auto_renewal_flag":true}'
        [200, {}, body]
      end

      client = build_client(stubs: stubs)
      result = client.fetch_stats(vendor_ref: "v-1",
                                  since: "2026-04-01T00:00:00Z",
                                  until_time: "2026-04-23T00:00:00Z")

      assert_equal :ok, result[:status]
      assert_in_delta 0.18, result[:stats]["sla_miss_ratio_30d"], 1e-6
      assert_equal 3, result[:stats]["obligation_breach_count_90d"]
      assert_equal true, result[:stats]["auto_renewal_flag"]
    end
  end

  test "disabled — returns :skipped without HTTP" do
    with_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # No stubs registered — any HTTP call would blow up.

      client = build_client(stubs: stubs)
      ob_res     = client.list_obligations(vendor_ref: "v-1")
      br_res     = client.list_breaches
      stats_res  = client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)

      [ob_res, br_res, stats_res].each do |r|
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
      result = client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)

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
      assert_raises(Ecosystem::TransientFailure) do
        client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)
      end
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
      5.times do
        assert_raises(Ecosystem::TransientFailure) do
          client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)
        end
      end

      assert_equal :open, breaker.status
      assert_raises(Ecosystem::CircuitOpen) do
        client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)
      end
    end
  end

  test "X-API-Key header sourced from CONTRACT_ENGINE_API_KEY env" do
    with_enabled do
      prev = ENV["CONTRACT_ENGINE_API_KEY"]
      ENV["CONTRACT_ENGINE_API_KEY"] = "specific-contract-key-xyz"
      begin
        captured = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/api/breaches") do |env|
          captured = env.request_headers["X-API-Key"]
          [200, {}, '{"breaches":[]}']
        end

        client = build_client(stubs: stubs)
        client.list_breaches
        assert_equal "specific-contract-key-xyz", captured
      ensure
        ENV["CONTRACT_ENGINE_API_KEY"] = prev
      end
    end
  end
end
