# frozen_string_literal: true

require "test_helper"
require "faraday"

# Ecosystem::RagPlatformClient — Faraday 2 client to the Multi-Agent RAG
# Platform (PRD §6.7 + §5.7). Read-only enrichment: pulls
# `GET /api/graph/entities?type=vendor&name=:normalized_name` and surfaces
# the result as `{status: :ok, entities: [...]}`. Mirrors HubClient /
# WorkflowClient / WebhookEngineClient — same retry + circuit-breaker
# pattern per `.claude/knowledge/foundation/ecosystem-client-pattern.md`.
#
# Standalone-first: when `RAG_PLATFORM_ENABLED != "true"`, every public
# method returns `{status: :skipped, ...}` immediately without HTTP.
#
# RAG Platform IS a third-party service per the mock policy in
# CODING_STANDARDS_TESTING_LIVE.md — `Faraday::Adapter::Test` is canonical.
class RagPlatformClientTest < ActiveSupport::TestCase
  def build_client(stubs:, breaker: nil)
    adapter = [:test, stubs]
    Ecosystem::RagPlatformClient.build(
      adapter: adapter,
      breaker: breaker,
      base_url: "http://rag.example.test"
    )
  end

  def with_enabled
    prev = ENV["RAG_PLATFORM_ENABLED"]
    ENV["RAG_PLATFORM_ENABLED"] = "true"
    yield
  ensure
    ENV["RAG_PLATFORM_ENABLED"] = prev
  end

  def with_disabled
    prev = ENV["RAG_PLATFORM_ENABLED"]
    ENV["RAG_PLATFORM_ENABLED"] = "false"
    yield
  ensure
    ENV["RAG_PLATFORM_ENABLED"] = prev
  end

  test "fetch_entities happy path returns array of entity rows" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/graph/entities") do |env|
        assert_equal "vendor", env.params["type"]
        assert_equal "alpha maschinenbau ag", env.params["name"]
        assert env.request_headers["X-API-Key"].present?
        body = '{"entities":[{"id":"ent-1","type":"vendor","name":"Alpha Maschinenbau AG",' \
               '"relationships":[{"type":"parent","target":"Alpha Holdings"}]}]}'
        [200, { "Content-Type" => "application/json" }, body]
      end

      client = build_client(stubs: stubs)
      result = client.fetch_entities(name: "alpha maschinenbau ag")

      assert_equal :ok, result[:status]
      assert_equal 1, result[:entities].length
      assert_equal "ent-1", result[:entities].first["id"]
      assert_equal 200, result[:response_code]
      stubs.verify_stubbed_calls
    end
  end

  test "fetch_entities returns empty array when RAG returns zero entities" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/graph/entities") do
        [200, { "Content-Type" => "application/json" }, '{"entities":[]}']
      end

      client = build_client(stubs: stubs)
      result = client.fetch_entities(name: "unknown vendor")

      assert_equal :ok, result[:status]
      assert_equal [], result[:entities]
    end
  end

  test "feature flag disabled — returns :skipped without HTTP" do
    with_disabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      # NOT registering any stub — any HTTP attempt would raise.
      client = build_client(stubs: stubs)
      result = client.fetch_entities(name: "alpha")

      assert_equal :skipped, result[:status]
      assert_match(/RAG/i, result[:reason])
    end
  end

  test "4xx returns :failed terminal" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/graph/entities") do
        [404, {}, '{"error":"not found"}']
      end

      client = build_client(stubs: stubs)
      result = client.fetch_entities(name: "missing")

      assert_equal :failed, result[:status]
      assert_equal 404, result[:response_code]
    end
  end

  test "5xx after retries raises TransientFailure" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.get("/api/graph/entities") do
        [503, {}, '{"error":"upstream"}']
      end

      client = build_client(stubs: stubs)
      assert_raises(Ecosystem::TransientFailure) do
        client.fetch_entities(name: "alpha")
      end
    end
  end

  test "circuit breaker open — short-circuits without HTTP" do
    with_enabled do
      stubs = Faraday::Adapter::Test::Stubs.new
      breaker = Ecosystem::CircuitBreaker.new
      # Trip the breaker manually by simulating failures
      5.times do
        begin
          breaker.call { raise StandardError, "boom" }
        rescue StandardError
          # expected
        end
      end

      client = build_client(stubs: stubs, breaker: breaker)
      assert_raises(Ecosystem::CircuitOpen) do
        client.fetch_entities(name: "alpha")
      end
    end
  end

  test "enabled? respects ENV var" do
    with_disabled do
      assert_equal false, build_client(stubs: Faraday::Adapter::Test::Stubs.new).enabled?
    end
    with_enabled do
      assert_equal true, build_client(stubs: Faraday::Adapter::Test::Stubs.new).enabled?
    end
  end
end
