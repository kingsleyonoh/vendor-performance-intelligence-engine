# frozen_string_literal: true

# VCR + WebMock setup — PRD §13.2 + §12 What-NOT #12.
#
# Every adapter MUST have fixture-backed integration tests so the suite
# runs in CI without network access. WebMock blocks real HTTP only
# while a VCR cassette is active; otherwise normal Faraday::Adapter::Test
# stubs and integration / e2e tests against docker services are
# unaffected.
#
# Mode:
#   record: :none — CI must NOT record. New cassettes are authored
#                   manually under `test/vcr_cassettes/` since we do not
#                   have ecosystem services running in CI to record from.
#
# Each cassette contains ONE happy-path request/response pair per
# adapter — this proves the Faraday wiring (URL, headers, retry,
# response parsing) is wired correctly without needing a live server.
#
# Scope: this support file is required explicitly by cassette tests in
# `test/lib/ecosystem/cassettes/*_test.rb`. Other tests (integration,
# system, e2e_api) are not affected — `WebMock.allow_net_connect!`
# leaves the default permissive so docker-hosted services and the
# in-process Rails server keep working.
require "vcr"
require "webmock"

VCR.configure do |c|
  c.cassette_library_dir = Rails.root.join("test/vcr_cassettes").to_s
  c.hook_into :webmock
  c.allow_http_connections_when_no_cassette = true
  c.default_cassette_options = {
    record: :none, # CI must not record; cassettes are committed
    match_requests_on: %i[method uri]
  }
  # Filter sensitive headers in any future re-recording.
  c.filter_sensitive_data("[FILTERED_API_KEY]") { ENV["NOTIFICATION_HUB_API_KEY"] }
  c.filter_sensitive_data("[FILTERED_API_KEY]") { ENV["WORKFLOW_ENGINE_API_KEY"] }
  c.filter_sensitive_data("[FILTERED_API_KEY]") { ENV["WEBHOOK_ENGINE_API_KEY"] }
  c.filter_sensitive_data("[FILTERED_API_KEY]") { ENV["INVOICE_RECON_API_KEY"] }
  c.filter_sensitive_data("[FILTERED_API_KEY]") { ENV["CONTRACT_ENGINE_API_KEY"] }
  c.filter_sensitive_data("[FILTERED_API_KEY]") { ENV["RECON_ENGINE_API_KEY"] }
end

# Default: real connections allowed. Cassette tests opt-in via
# `VCR.use_cassette` which switches WebMock to intercept-only mode for
# the duration of the block.
WebMock.allow_net_connect!
