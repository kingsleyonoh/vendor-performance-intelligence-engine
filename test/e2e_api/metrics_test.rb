require "test_helper"
require "net/http"
require "uri"
require "base64"
require_relative "e2e_test_helper"

# E2E test for /metrics — hits a RUNNING Puma via real HTTP.
# Verifies the route is wired through the full Rack stack, the Auth
# middleware allowlist passes /metrics through (no X-API-Key needed), and
# Basic Auth gating works end-to-end.
class MetricsE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  def setup
    @port = ENV.fetch("E2E_PORT", "3001").to_i
  end

  test "GET /metrics without Basic Auth returns 401" do
    uri = URI("http://127.0.0.1:#{@port}/metrics")
    response = Net::HTTP.get_response(uri)
    assert_equal "401", response.code,
                 "Expected 401 from /metrics without auth, got #{response.code}: #{response.body[0, 200]}"
  end

  test "GET /metrics with correct Basic Auth returns 200 + Prometheus exposition" do
    uri = URI("http://127.0.0.1:#{@port}/metrics")
    # ServerBoot forces these creds for the spawned Puma so the test is
    # deterministic regardless of host env. Match them exactly here.
    user = "metrics"
    pass = "changeme"
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(user, pass)
    response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }

    assert_equal "200", response.code, "Expected 200, got #{response.code}: #{response.body[0, 200]}"
    ct = response["content-type"].to_s
    assert ct.start_with?("text/plain"), "Expected text/plain, got #{ct}"
    assert_match(/# (HELP|TYPE)/, response.body, "Body should contain Prometheus HELP/TYPE comments")
    assert_match(/vpi_/, response.body, "Body should expose vpi_ prefixed metrics")
  end
end
