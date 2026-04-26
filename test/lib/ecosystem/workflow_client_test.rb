# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::WorkflowClient — Faraday 2 client to the Workflow Automation
# Engine (PRD §6.2 + §13.2). Mirrors HubClient — same retry, circuit-breaker,
# and lifecycle contract per `.claude/knowledge/foundation/ecosystem-client-pattern.md`.
#
# Workflow Engine IS a third-party service per the mock policy in
# CODING_STANDARDS_TESTING_LIVE.md — `Faraday::Adapter::Test` is the canonical
# mock. Local services (Postgres, Redis) are NOT touched here.
class WorkflowClientTest < ActiveSupport::TestCase
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::WorkflowClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://workflow.example.test"
    )
  end

  def with_workflow_enabled
    prev = ENV["WORKFLOW_ENGINE_ENABLED"]
    ENV["WORKFLOW_ENGINE_ENABLED"] = "true"
    yield
  ensure
    ENV["WORKFLOW_ENGINE_ENABLED"] = prev
  end

  def with_workflow_disabled
    prev = ENV["WORKFLOW_ENGINE_ENABLED"]
    ENV["WORKFLOW_ENGINE_ENABLED"] = "false"
    yield
  ensure
    ENV["WORKFLOW_ENGINE_ENABLED"] = prev
  end

  test "happy path — 200 returns executed + execution_id" do
    with_workflow_enabled do
      prev_key = ENV["WORKFLOW_ENGINE_API_KEY"]
      ENV["WORKFLOW_ENGINE_API_KEY"] = "wf-test-key"
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/api/workflows/wf-vpi-escalation/execute") do |env|
        assert_equal "wf-test-key", env.request_headers["X-API-Key"]
        assert_equal "vpi/0.1 (faraday)", env.request_headers["User-Agent"]
        [200, { "Content-Type" => "application/json" }, '{"execution_id":"exec-abc-123"}']
      end

      client = build_client(stubs: stubs)
      result = client.execute(workflow_id: "wf-vpi-escalation", payload: { alert_id: "a-1" })

      assert_equal :executed, result[:status]
      assert_equal "exec-abc-123", result[:execution_id]
      assert_equal 200, result[:response_code]
      stubs.verify_stubbed_calls
    ensure
      ENV["WORKFLOW_ENGINE_API_KEY"] = prev_key
    end
  end

  test "disabled — returns :skipped and makes no HTTP call" do
    with_workflow_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new

      client = build_client(stubs: stubs)
      result = client.execute(workflow_id: "wf-x", payload: {})

      assert_equal :skipped, result[:status]
      assert_match(/disabled/i, result[:reason])
      stubs.verify_stubbed_calls
    end
  end

  test "4xx terminal — returns :failed without retrying" do
    with_workflow_enabled do
      call_count = 0
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/api/workflows/wf-broken/execute") do |_env|
        call_count += 1
        [422, { "Content-Type" => "application/json" }, '{"error":"workflow not registered"}']
      end

      client = build_client(stubs: stubs)
      result = client.execute(workflow_id: "wf-broken", payload: {})

      assert_equal :failed, result[:status]
      assert_equal 422, result[:response_code]
      assert_equal "workflow not registered", result[:error]
      assert_equal 1, call_count, "4xx must NOT trigger retries"
    end
  end

  test "5xx with retry exhausted — raises TransientFailure" do
    with_workflow_enabled do
      call_count = 0
      stubs = Faraday::Adapter::Test::Stubs.new
      4.times do
        stubs.post("/api/workflows/wf-x/execute") do |_env|
          call_count += 1
          [503, { "Content-Type" => "application/json" }, '{"error":"unavailable"}']
        end
      end

      client = build_client(stubs: stubs)
      assert_raises(Ecosystem::TransientFailure) do
        client.execute(workflow_id: "wf-x", payload: {})
      end
      assert_operator call_count, :>=, 1
    end
  end

  test "network failure raises TransientFailure" do
    with_workflow_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      10.times do
        stubs.post("/api/workflows/wf-x/execute") { |_env| raise Faraday::ConnectionFailed.new("conn refused") }
      end

      client = build_client(stubs: stubs)
      assert_raises(Ecosystem::TransientFailure) do
        client.execute(workflow_id: "wf-x", payload: {})
      end
    end
  end

  test "circuit breaker opens after 5 failures and short-circuits" do
    with_workflow_enabled do
      breaker = Ecosystem::CircuitBreaker.new(failure_threshold: 5, window_seconds: 60, cooldown_seconds: 60)
      stubs = Faraday::Adapter::Test::Stubs.new
      40.times { stubs.post("/api/workflows/wf-x/execute") { |_| [503, {}, "{}"] } }

      client = build_client(stubs: stubs, breaker: breaker)

      5.times do
        assert_raises(Ecosystem::TransientFailure) { client.execute(workflow_id: "wf-x", payload: {}) }
      end

      assert_equal :open, breaker.status

      assert_raises(Ecosystem::CircuitOpen) { client.execute(workflow_id: "wf-x", payload: {}) }
    end
  end

  test "X-API-Key header sourced from WORKFLOW_ENGINE_API_KEY env" do
    with_workflow_enabled do
      prev = ENV["WORKFLOW_ENGINE_API_KEY"]
      ENV["WORKFLOW_ENGINE_API_KEY"] = "specific-wf-key-xyz"
      begin
        captured_key = nil
        stubs = Faraday::Adapter::Test::Stubs.new
        stubs.post("/api/workflows/wf-1/execute") do |env|
          captured_key = env.request_headers["X-API-Key"]
          [200, {}, '{"execution_id":"e-1"}']
        end

        client = build_client(stubs: stubs)
        client.execute(workflow_id: "wf-1", payload: {})
        assert_equal "specific-wf-key-xyz", captured_key
      ensure
        ENV["WORKFLOW_ENGINE_API_KEY"] = prev
      end
    end
  end

  test "execute payload is JSON-encoded under workflow_id path" do
    with_workflow_enabled do
      captured_body = nil
      captured_path = nil
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.post("/api/workflows/escalate-critical/execute") do |env|
        captured_body = env.body
        captured_path = env.url.path
        [200, {}, '{"execution_id":"e-1"}']
      end

      client = build_client(stubs: stubs)
      client.execute(workflow_id: "escalate-critical", payload: { alert_id: "a-1", vendor: { id: "v-1" } })

      assert_equal "/api/workflows/escalate-critical/execute", captured_path
      parsed = JSON.parse(captured_body)
      assert_equal "a-1", parsed["alert_id"]
      assert_equal "v-1", parsed.dig("vendor", "id")
    end
  end
end
