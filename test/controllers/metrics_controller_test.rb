# frozen_string_literal: true

require "test_helper"

# Prometheus /metrics endpoint — PRD §10b.
#
# - Basic Auth gated by METRICS_BASIC_AUTH_USER + METRICS_BASIC_AUTH_PASS.
# - Allowlisted in Auth::ApiKeyAuthenticator (no X-API-Key needed — Prometheus
#   scrape jobs don't carry tenant credentials).
# - Disabled (404) when PROMETHEUS_ENABLED=false.
# - Returns Prometheus exposition format text (Content-Type:
#   text/plain; version=0.0.4).
class MetricsControllerTest < ActionDispatch::IntegrationTest
  def setup
    @original_enabled = ENV["PROMETHEUS_ENABLED"]
    @original_user    = ENV["METRICS_BASIC_AUTH_USER"]
    @original_pass    = ENV["METRICS_BASIC_AUTH_PASS"]
    ENV["PROMETHEUS_ENABLED"]      = "true"
    ENV["METRICS_BASIC_AUTH_USER"] = "metrics"
    ENV["METRICS_BASIC_AUTH_PASS"] = "secret"
  end

  def teardown
    ENV["PROMETHEUS_ENABLED"]      = @original_enabled
    ENV["METRICS_BASIC_AUTH_USER"] = @original_user
    ENV["METRICS_BASIC_AUTH_PASS"] = @original_pass
  end

  test "GET /metrics without Basic Auth returns 401" do
    get "/metrics"
    assert_equal 401, response.status
  end

  test "GET /metrics with wrong credentials returns 401" do
    get "/metrics", headers: basic_auth_headers("wrong", "creds")
    assert_equal 401, response.status
  end

  test "GET /metrics with correct credentials returns 200 and Prometheus exposition" do
    get "/metrics", headers: basic_auth_headers("metrics", "secret")
    assert_equal 200, response.status
    assert_match %r{text/plain}, response.headers["Content-Type"]
    # Prometheus exposition begins with `# HELP` or `# TYPE` lines for each metric.
    body = response.body
    assert_match(/# (HELP|TYPE)/, body, "Body should contain Prometheus HELP/TYPE comments")
  end

  test "GET /metrics returns 404 when PROMETHEUS_ENABLED=false" do
    ENV["PROMETHEUS_ENABLED"] = "false"
    get "/metrics", headers: basic_auth_headers("metrics", "secret")
    assert_equal 404, response.status
  end

  test "/metrics is public-allowlisted (no X-API-Key required)" do
    # The auth middleware should NOT challenge for /metrics. With correct
    # Basic Auth we get 200 even without X-API-Key.
    get "/metrics", headers: basic_auth_headers("metrics", "secret")
    assert_equal 200, response.status
  end

  test "exposition includes process metrics by default" do
    get "/metrics", headers: basic_auth_headers("metrics", "secret")
    assert_equal 200, response.status
    # Default registry exposes process_resident_memory_bytes etc. when
    # the Process collector is registered.
    assert_match(/vpi_/, response.body, "Body should expose vpi_ prefixed metrics")
  end

  private

  def basic_auth_headers(user, pass)
    { "HTTP_AUTHORIZATION" => ActionController::HttpAuthentication::Basic.encode_credentials(user, pass) }
  end
end
