# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require "openssl"
require_relative "e2e_test_helper"

# E2E for the HMAC-authenticated Hub fanout endpoint — PRD §5, §8, §13.2.
#
# Endpoints exercised (all via real HTTP):
#   POST /api/tenants/register      (create tenant for from-hub routing)
#   POST /api/signals/from-hub      (HMAC-signed; allowlisted, no X-API-Key)
class FromHubFlowE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  BASE_URL = ENV.fetch("E2E_BASE_URL", "http://127.0.0.1:3001")
  # Server boots with this secret in test env (see ServerBoot).
  HUB_SECRET = ENV.fetch("HUB_INGRESS_SECRET", "test-hub-ingress-secret-32bytes!")

  def post_json(path, body, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = body.is_a?(String) ? body : body.to_json
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def signed_post(path, payload, secret: HUB_SECRET, ts: Time.now.to_i)
    body = payload.to_json
    sig = OpenSSL::HMAC.hexdigest("SHA256", secret, "#{ts}.#{body}")
    post_json(path, body, headers: { "X-VPI-Signature" => "t=#{ts},v1=#{sig}" })
  end

  def register_tenant(suffix)
    body = {
      slug: "e2e-fromhub-#{suffix}",
      legal_name: "E2E FromHub #{suffix}",
      full_legal_name: "E2E FromHub #{suffix} Ltd",
      display_name: "E2EFH#{suffix}",
      address: { line1: "1 Hub Way", city: "Hubville", country_code: "GB" },
      registration: { tax_id: "GB-FH-#{suffix}", company_number: "FH#{suffix}" },
      contact: { email: "fh#{suffix}@e2e.example" }
    }
    res = nil
    4.times do
      res = post_json("/api/tenants/register", body)
      break if res.code != "429"
      sleep 15
    end
    assert_equal "201", res.code, "register failed: #{res.code} #{res.body}"
    JSON.parse(res.body).fetch("tenant_slug") rescue body[:slug]
    body[:slug]
  end

  test "valid HMAC + tenant_slug → 202 and signal stored" do
    suffix = Time.now.to_i.to_s
    slug = register_tenant(suffix)

    payload = {
      tenant_slug: slug,
      vendor_ref: { normalized_name: "fromhub vendor", tax_id: "DE-FH-#{suffix}" },
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "evt-fromhub-#{suffix}",
      value_numeric: 0.21,
      recorded_at: Time.now.utc.iso8601
    }

    res = signed_post("/api/signals/from-hub", payload)
    assert_equal "202", res.code, "expected 202 from /api/signals/from-hub: #{res.code} #{res.body}"
    body = JSON.parse(res.body)
    assert_includes %w[accepted deduped], body["status"]
  end

  test "invalid HMAC signature → 401 INVALID_SIGNATURE" do
    suffix = Time.now.to_i.to_s + "-bad"
    slug = register_tenant(suffix)

    payload = { tenant_slug: slug, signal_code: "invoice.late_ratio_30d" }
    body = payload.to_json
    res = post_json("/api/signals/from-hub", body,
                    headers: { "X-VPI-Signature" => "t=#{Time.now.to_i},v1=deadbeef00" })
    assert_equal "401", res.code
    err = JSON.parse(res.body).dig("error", "code")
    assert_equal "INVALID_SIGNATURE", err
  end

  test "unknown tenant_slug → 404 INVALID_TENANT" do
    payload = {
      tenant_slug: "no-such-tenant-#{Time.now.to_i}",
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "evt-x",
      value_numeric: 0.1,
      recorded_at: Time.now.utc.iso8601,
      vendor_ref: { normalized_name: "x" }
    }
    res = signed_post("/api/signals/from-hub", payload)
    assert_equal "404", res.code, res.body
    err = JSON.parse(res.body).dig("error", "code")
    assert_equal "INVALID_TENANT", err
  end
end
