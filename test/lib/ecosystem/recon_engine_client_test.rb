# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::ReconEngineClient — Faraday 2 client to the Transaction
# Reconciliation Engine (PRD §6 + §13.2). Mirrors Hub/Workflow/Webhook/
# InvoiceRecon/ContractEngine clients. Per the mock policy in
# CODING_STANDARDS_TESTING_LIVE.md, this is a third-party service so
# `Faraday::Adapter::Test` is canonical.
class ReconEngineClientTest < ActiveSupport::TestCase
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::ReconEngineClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://recon-engine.example.test"
    )
  end

  def with_enabled
    prev = ENV["RECON_ENGINE_ENABLED"]
    ENV["RECON_ENGINE_ENABLED"] = "true"
    yield
  ensure
    ENV["RECON_ENGINE_ENABLED"] = prev
  end

  def with_disabled
    prev = ENV["RECON_ENGINE_ENABLED"]
    ENV["RECON_ENGINE_ENABLED"] = "false"
    yield
  ensure
    ENV["RECON_ENGINE_ENABLED"] = prev
  end

  test "list_discrepancies happy path returns array" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/v1/discrepancies") do |env|
        assert env.request_headers["X-API-Key"].present?
        assert_includes env.url.query.to_s, "source=vendor"
        [200, { "Content-Type" => "application/json" },
         '{"discrepancies":[{"id":"dx-1","vendor_ref":"v-1","amount":42.0}],"page":1,"total":1}']
      end

      client = build_client(stubs: stubs)
      result = client.list_discrepancies(source: "vendor", since: "2026-04-01T00:00:00Z", page: 1)

      assert_equal :ok, result[:status]
      assert_equal 1, result[:discrepancies].length
      assert_equal "dx-1", result[:discrepancies].first["id"]
      stubs.verify_stubbed_calls
    end
  end

  test "fetch_stats happy path returns ratios" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/v1/stats") do |env|
        assert_includes env.url.query.to_s, "vendor_ref="
        body = '{"discrepancy_rate_30d":0.07,"unmatched_payment_count_7d":3,' \
               '"reject_rate_30d":0.04,"late_settlement_count_90d":5}'
        [200, {}, body]
      end

      client = build_client(stubs: stubs)
      result = client.fetch_stats(vendor_ref: "v-1",
                                  since: "2026-04-01T00:00:00Z",
                                  until_time: "2026-04-23T00:00:00Z")

      assert_equal :ok, result[:status]
      assert_in_delta 0.07, result[:stats]["discrepancy_rate_30d"], 1e-6
      assert_equal 3, result[:stats]["unmatched_payment_count_7d"]
    end
  end

  test "disabled — returns :skipped without HTTP" do
    with_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # No stubs registered — any HTTP call would blow up.

      client = build_client(stubs: stubs)
      list_res  = client.list_discrepancies(source: "vendor")
      stats_res = client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)

      [list_res, stats_res].each do |r|
        assert_equal :skipped, r[:status]
        assert_match(/disabled/i, r[:reason])
      end
    end
  end

  test "4xx terminal — returns :failed without retrying" do
    with_enabled do
      call_count = 0
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/v1/stats") do |_env|
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
        stubs.get("/api/v1/stats") { |_| [503, {}, '{"error":"unavailable"}'] }
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
      40.times { stubs.get("/api/v1/stats") { |_| [503, {}, "{}"] } }

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

  test "X-API-Key header sourced from RECON_ENGINE_API_KEY env" do
    with_enabled do
      prev = ENV["RECON_ENGINE_API_KEY"]
      ENV["RECON_ENGINE_API_KEY"] = "specific-recon-key-xyz"
      begin
        captured = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/api/v1/discrepancies") do |env|
          captured = env.request_headers["X-API-Key"]
          [200, {}, '{"discrepancies":[]}']
        end

        client = build_client(stubs: stubs)
        client.list_discrepancies(source: "vendor")
        assert_equal "specific-recon-key-xyz", captured
      ensure
        ENV["RECON_ENGINE_API_KEY"] = prev
      end
    end
  end

  test "list_discrepancies defaults source param to vendor" do
    with_enabled do
      captured_query = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/v1/discrepancies") do |env|
        captured_query = env.url.query.to_s
        [200, {}, '{"discrepancies":[]}']
      end

      client = build_client(stubs: stubs)
      client.list_discrepancies # no args
      assert_includes captured_query, "source=vendor"
    end
  end
end
