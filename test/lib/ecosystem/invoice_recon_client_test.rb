# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::InvoiceReconClient — Faraday 2 client to the Invoice
# Reconciliation Engine (PRD §6 + §13.2). Mirrors HubClient/WorkflowClient/
# WebhookEngineClient. Per the mock policy in CODING_STANDARDS_TESTING_LIVE.md,
# this is a third-party service so `Faraday::Adapter::Test` is canonical.
class InvoiceReconClientTest < ActiveSupport::TestCase
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::InvoiceReconClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://invoice-recon.example.test"
    )
  end

  def with_enabled
    prev = ENV["INVOICE_RECON_ENABLED"]
    ENV["INVOICE_RECON_ENABLED"] = "true"
    yield
  ensure
    ENV["INVOICE_RECON_ENABLED"] = prev
  end

  def with_disabled
    prev = ENV["INVOICE_RECON_ENABLED"]
    ENV["INVOICE_RECON_ENABLED"] = "false"
    yield
  ensure
    ENV["INVOICE_RECON_ENABLED"] = prev
  end

  test "list_late_invoices happy path returns array" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/late-invoices") do |env|
        assert env.request_headers["X-API-Key"].present?
        assert_includes env.url.query.to_s, "since="
        [200, { "Content-Type" => "application/json" },
         '{"invoices":[{"id":"inv-1","vendor_ref":"v-1","days_late":5}],"page":1,"total":1}']
      end

      client = build_client(stubs: stubs)
      result = client.list_late_invoices(since: "2026-04-01T00:00:00Z", page: 1)

      assert_equal :ok, result[:status]
      assert_equal 1, result[:invoices].length
      assert_equal "inv-1", result[:invoices].first["id"]
      stubs.verify_stubbed_calls
    end
  end

  test "list_disputes happy path returns array" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/disputes") do |env|
        [200, {}, '{"disputes":[{"id":"d-1","status":"open"}]}']
      end

      client = build_client(stubs: stubs)
      result = client.list_disputes(since: "2026-04-01T00:00:00Z")

      assert_equal :ok, result[:status]
      assert_equal 1, result[:disputes].length
    end
  end

  test "fetch_stats happy path returns ratios" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/stats") do |env|
        assert_includes env.url.query.to_s, "vendor_ref="
        body = '{"late_ratio_30d":0.18,"dispute_rate_90d":0.05,' \
               '"avg_days_to_pay":17.4,"overbilling_rate_30d":0.02}'
        [200, {}, body]
      end

      client = build_client(stubs: stubs)
      result = client.fetch_stats(vendor_ref: "v-1",
                                  since: "2026-04-01T00:00:00Z",
                                  until_time: "2026-04-23T00:00:00Z")

      assert_equal :ok, result[:status]
      assert_in_delta 0.18, result[:stats]["late_ratio_30d"], 1e-6
      assert_in_delta 17.4, result[:stats]["avg_days_to_pay"], 1e-6
    end
  end

  test "disabled — returns :skipped without HTTP" do
    with_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # No stubs registered — any HTTP call would blow up.

      client = build_client(stubs: stubs)
      late_res    = client.list_late_invoices
      disputes_res = client.list_disputes
      stats_res    = client.fetch_stats(vendor_ref: "v-1", since: nil, until_time: nil)

      [late_res, disputes_res, stats_res].each do |r|
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

  test "X-API-Key header sourced from INVOICE_RECON_API_KEY env" do
    with_enabled do
      prev = ENV["INVOICE_RECON_API_KEY"]
      ENV["INVOICE_RECON_API_KEY"] = "specific-invoice-key-xyz"
      begin
        captured = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.get("/api/disputes") do |env|
          captured = env.request_headers["X-API-Key"]
          [200, {}, '{"disputes":[]}']
        end

        client = build_client(stubs: stubs)
        client.list_disputes
        assert_equal "specific-invoice-key-xyz", captured
      ensure
        ENV["INVOICE_RECON_API_KEY"] = prev
      end
    end
  end
end
