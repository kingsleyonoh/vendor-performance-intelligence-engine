# frozen_string_literal: true

require "test_helper"

# CORS integration test — verifies `config/initializers/cors.rb` is wired BEFORE
# routing (so preflight OPTIONS responses carry the right headers) and honors
# the `ALLOWED_ORIGINS` env var. Runs through the real Rack stack — no mocks.
class CorsTest < ActionDispatch::IntegrationTest
  ALLOWED_ORIGIN = "http://localhost:3000"
  DISALLOWED_ORIGIN = "http://evil.example.com"

  test "preflight OPTIONS from an allowed origin returns CORS headers" do
    # ALLOWED_ORIGINS is pre-loaded by dotenv-rails via test.env / .env.local
    # in the compose stack. Assert what the initializer actually whitelisted.
    skip "ALLOWED_ORIGINS not configured in test env" if ENV["ALLOWED_ORIGINS"].to_s.empty?

    process :options,
      "/api/anything",
      headers: {
        "HTTP_ORIGIN" => ALLOWED_ORIGIN,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST",
        "HTTP_ACCESS_CONTROL_REQUEST_HEADERS" => "X-API-Key, Content-Type"
      }

    assert_equal ALLOWED_ORIGIN, response.headers["Access-Control-Allow-Origin"]
    allow_methods = response.headers["Access-Control-Allow-Methods"].to_s
    assert_match(/POST/i, allow_methods)
    assert_match(/GET/i, allow_methods)
    assert_match(/DELETE/i, allow_methods)
  end

  test "preflight from a disallowed origin does not emit Access-Control-Allow-Origin" do
    skip "ALLOWED_ORIGINS not configured in test env" if ENV["ALLOWED_ORIGINS"].to_s.empty?

    process :options,
      "/api/anything",
      headers: {
        "HTTP_ORIGIN" => DISALLOWED_ORIGIN,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "POST"
      }

    # rack-cors simply declines to set the header when origin is not allowed.
    # Browsers then block the request.
    refute_equal DISALLOWED_ORIGIN, response.headers["Access-Control-Allow-Origin"]
  end

  test "preflight exposes rate-limit headers via Access-Control-Expose-Headers" do
    skip "ALLOWED_ORIGINS not configured in test env" if ENV["ALLOWED_ORIGINS"].to_s.empty?

    process :options,
      "/api/anything",
      headers: {
        "HTTP_ORIGIN" => ALLOWED_ORIGIN,
        "HTTP_ACCESS_CONTROL_REQUEST_METHOD" => "GET"
      }

    exposed = response.headers["Access-Control-Expose-Headers"].to_s
    assert_match(/X-RateLimit-Remaining/i, exposed)
    assert_match(/X-RateLimit-Reset/i, exposed)
  end
end
