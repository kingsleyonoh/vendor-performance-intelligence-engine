# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require_relative "e2e_test_helper"

# Shell-level E2E smoke against the Rails 8 built-in authentication routes
# scaffolded in Batch 005. `bin/rake test:e2e` boots Puma on port 3001 then
# runs this file. We hit GET /session/new (the login page) and assert it
# responds with HTML 200 — the minimum signal that the generator output is
# wired into the route table and renders without an ActionView exception.
#
# Deeper behavior (session creation, cookie lifetime, password reset email)
# is covered by the generated `test/controllers/sessions_controller_test.rb`
# via in-process IntegrationTest.
class AuthEndpointsSmokeE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  BASE_URL = ENV.fetch("E2E_BASE_URL", "http://127.0.0.1:3001")

  test "GET /session/new returns HTML 200 against running Puma" do
    uri = URI.join(BASE_URL, "/session/new")
    response = Net::HTTP.get_response(uri)

    assert_equal "200", response.code,
                 "GET /session/new must render the login page (got #{response.code}: #{response.body[0, 200]})"
    assert_match(/text\/html/, response["content-type"].to_s,
                 "login page must be HTML")
  end

  test "GET /passwords/new returns HTML 200 against running Puma" do
    uri = URI.join(BASE_URL, "/passwords/new")
    response = Net::HTTP.get_response(uri)

    assert_equal "200", response.code,
                 "GET /passwords/new must render the password-reset request page"
    assert_match(/text\/html/, response["content-type"].to_s)
  end
end
