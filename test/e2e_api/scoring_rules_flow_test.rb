# frozen_string_literal: true

require "test_helper"
require "net/http"
require "uri"
require "json"
require_relative "e2e_test_helper"

# E2E for /api/scoring_rules — PRD §4.6, §5, §8b.
#
# Exercises CRUD + activate + preview against a real booted Puma:
#   POST   /api/tenants/register
#   GET    /api/scoring_rules
#   POST   /api/scoring_rules
#   GET    /api/scoring_rules/:id
#   PATCH  /api/scoring_rules/:id
#   POST   /api/scoring_rules/:id/activate
#   POST   /api/scoring_rules/:id/preview
#   DELETE /api/scoring_rules/:id
class ScoringRulesFlowE2ETest < ActiveSupport::TestCase
  include E2ETestHelper

  BASE_URL = ENV.fetch("E2E_BASE_URL", "http://127.0.0.1:3001")

  def post_json(path, body, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = body.to_json
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def patch_json(path, body, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Patch.new(uri)
    req["Content-Type"] = "application/json"
    headers.each { |k, v| req[k] = v }
    req.body = body.to_json
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def get_json(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Get.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def delete_json(path, headers: {})
    uri = URI.join(BASE_URL, path)
    req = Net::HTTP::Delete.new(uri)
    headers.each { |k, v| req[k] = v }
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(req) }
  end

  def register_tenant(suffix)
    body = {
      slug: "e2e-sr-#{suffix}",
      legal_name: "E2E SR #{suffix}",
      full_legal_name: "E2E SR #{suffix} Ltd",
      display_name: "E2ESR#{suffix}",
      address: { line1: "1 Rule Ave", city: "Rulesville", country_code: "GB" },
      registration: { tax_id: "GB-SR-#{suffix}", company_number: "SR#{suffix}" },
      contact: { email: "sr#{suffix}@e2e.example" }
    }
    # Rack::Attack 5/min/IP on /api/tenants/register: retry with back-off
    # when the suite has exhausted the window. Real production clients
    # would space their own register calls, but the test suite fires them
    # sequentially inside seconds.
    res = nil
    4.times do
      res = post_json("/api/tenants/register", body)
      break if res.code != "429"

      sleep 15
    end
    assert_equal "201", res.code, "register failed: #{res.code} #{res.body}"
    JSON.parse(res.body).fetch("api_key")
  end

  test "CRUD + activate + preview for scoring_rules over real HTTP" do
    suffix = Time.now.to_i.to_s
    key = register_tenant(suffix)
    headers = { "X-API-Key" => key }

    # List — freshly-registered tenants start with zero rules until the
    # Phase 1 default-rule auto-seed lands. Either empty or pre-seeded.
    list_res = get_json("/api/scoring_rules", headers: headers)
    assert_equal "200", list_res.code, list_res.body
    assert JSON.parse(list_res.body).key?("scoring_rules")

    # 1. Create a draft rule (is_active=false)
    draft_body = {
      name: "Tuning E2E #{suffix}",
      category_weights: { financial: 0.30, operational: 0.20, contractual: 0.25,
                          integration: 0.15, transactional: 0.10 },
      band_thresholds: { low_max: 20, medium_max: 45, high_max: 70 },
      window_days: 60,
      time_decay_half_life_days: 30
    }
    create_res = post_json("/api/scoring_rules", draft_body, headers: headers)
    assert_equal "201", create_res.code, create_res.body
    draft = JSON.parse(create_res.body).fetch("scoring_rule")
    assert_equal false, draft["is_active"]
    draft_id = draft["id"]

    # 2. Show
    show_res = get_json("/api/scoring_rules/#{draft_id}", headers: headers)
    assert_equal "200", show_res.code

    # 3. Update (patch window_days)
    update_res = patch_json("/api/scoring_rules/#{draft_id}",
                            { window_days: 90 }, headers: headers)
    assert_equal "200", update_res.code, update_res.body
    assert_equal 90, JSON.parse(update_res.body).dig("scoring_rule", "window_days")

    # 4. Preview (no vendor_ids → engine samples up to 10)
    preview_res = post_json("/api/scoring_rules/#{draft_id}/preview", {}, headers: headers)
    assert_equal "200", preview_res.code, preview_res.body
    preview_json = JSON.parse(preview_res.body)
    assert preview_json.key?("previews")
    assert preview_json.dig("summary", "total_previewed").is_a?(Integer)

    # 5. Activate
    activate_res = post_json("/api/scoring_rules/#{draft_id}/activate", {}, headers: headers)
    assert_equal "200", activate_res.code, activate_res.body
    assert_equal true, JSON.parse(activate_res.body).dig("scoring_rule", "is_active")

    # 6. Deleting the now-active rule must 409
    delete_res = delete_json("/api/scoring_rules/#{draft_id}", headers: headers)
    assert_equal "409", delete_res.code, "deleting active rule should conflict; got #{delete_res.code}"
  end
end
