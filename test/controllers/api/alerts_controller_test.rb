# frozen_string_literal: true

require "test_helper"

# AlertsController — PRD §5, §8, §8b, §13.2.
# Endpoints: index, show, acknowledge, suppress, retry. All require
# X-API-Key, all 404 on cross-tenant alert id.
class Api::AlertsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @other  = tenants(:globex_inc_us)
    @vendor = vendors(:acme_alpha)
    @score  = vendor_scores(:acme_alpha_current)
    @other_vendor = vendors(:globex_zeta)
    @other_score  = vendor_scores(:globex_zeta_current)
    @raw_acme   = "vpi_test_acme_key_00000000000000000000"
    @raw_globex = "vpi_test_globex_key_00000000000000000"

    @alert = create_alert(
      tenant: @tenant, vendor: @vendor, score: @score,
      status: "pending"
    )
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  # ---------- GET /api/alerts ----------

  test "GET /api/alerts lists current tenant's alerts only" do
    create_alert(tenant: @other, vendor: @other_vendor, score: @other_score, status: "pending")

    get "/api/alerts", headers: { "X-API-Key" => @raw_acme }
    assert_response :ok
    body = JSON.parse(response.body)
    assert body["alerts"].is_a?(Array)
    assert_equal 1, body["alerts"].size
    assert_equal @alert.id, body["alerts"].first["id"]
  end

  test "GET /api/alerts filters by status" do
    other_score = vendor_scores(:acme_alpha_history_1)
    create_alert(tenant: @tenant, vendor: @vendor, score: other_score, status: "delivered")

    get "/api/alerts", params: { status: "delivered" }, headers: { "X-API-Key" => @raw_acme }
    assert_response :ok
    body = JSON.parse(response.body)
    assert(body["alerts"].all? { |a| a["status"] == "delivered" })
    assert_equal 1, body["alerts"].size
  end

  test "GET /api/alerts filters by band (new_band)" do
    other_score = vendor_scores(:acme_alpha_history_1)
    create_alert(tenant: @tenant, vendor: @vendor, score: other_score, status: "pending", new_band: "critical")

    get "/api/alerts", params: { band: "critical" }, headers: { "X-API-Key" => @raw_acme }
    assert_response :ok
    body = JSON.parse(response.body)
    assert(body["alerts"].all? { |a| a["new_band"] == "critical" })
  end

  test "GET /api/alerts requires X-API-Key" do
    get "/api/alerts"
    assert_response :unauthorized
  end

  # ---------- GET /api/alerts/:id ----------

  test "GET /api/alerts/:id returns the alert with delivery_payload" do
    get "/api/alerts/#{@alert.id}", headers: { "X-API-Key" => @raw_acme }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal @alert.id, body["alert"]["id"]
    assert body["alert"]["delivery_payload"].is_a?(Hash)
  end

  test "GET /api/alerts/:id 404s on cross-tenant id" do
    get "/api/alerts/#{@alert.id}", headers: { "X-API-Key" => @raw_globex }
    assert_response :not_found
  end

  # ---------- POST /api/alerts/:id/acknowledge ----------

  test "POST acknowledge transitions delivered → acknowledged" do
    @alert.update_columns(status: "delivered")

    post "/api/alerts/#{@alert.id}/acknowledge", headers: { "X-API-Key" => @raw_acme }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "acknowledged", body["alert"]["status"]
    assert_not_nil body["alert"]["acknowledged_at"]
  end

  test "POST acknowledge twice returns 409 CONFLICT" do
    @alert.update_columns(status: "delivered")
    post "/api/alerts/#{@alert.id}/acknowledge", headers: { "X-API-Key" => @raw_acme }
    assert_response :ok

    post "/api/alerts/#{@alert.id}/acknowledge", headers: { "X-API-Key" => @raw_acme }
    assert_response :conflict
  end

  test "POST acknowledge 404s on cross-tenant id" do
    @alert.update_columns(status: "delivered")
    post "/api/alerts/#{@alert.id}/acknowledge", headers: { "X-API-Key" => @raw_globex }
    assert_response :not_found
  end

  # ---------- POST /api/alerts/:id/suppress ----------

  test "POST suppress sets status='suppressed' + suppressed_until" do
    until_iso = (Time.now.utc + 12.hours).iso8601
    post "/api/alerts/#{@alert.id}/suppress",
         params: { until: until_iso }.to_json,
         headers: { "X-API-Key" => @raw_acme, "Content-Type" => "application/json" }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "suppressed", body["alert"]["status"]
    assert_not_nil body["alert"]["suppressed_until"]
  end

  test "POST suppress with past `until` returns 400" do
    past = (Time.now.utc - 1.hour).iso8601
    post "/api/alerts/#{@alert.id}/suppress",
         params: { until: past }.to_json,
         headers: { "X-API-Key" => @raw_acme, "Content-Type" => "application/json" }
    assert_response :bad_request
  end

  test "POST suppress 404s on cross-tenant id" do
    until_iso = (Time.now.utc + 12.hours).iso8601
    post "/api/alerts/#{@alert.id}/suppress",
         params: { until: until_iso }.to_json,
         headers: { "X-API-Key" => @raw_globex, "Content-Type" => "application/json" }
    assert_response :not_found
  end

  # ---------- POST /api/alerts/:id/retry ----------

  test "POST retry on failed alert flips status to pending and enqueues HubDispatchJob" do
    @alert.update_columns(status: "failed", last_error: "previous fail", dispatch_attempts: 1)

    post "/api/alerts/#{@alert.id}/retry", headers: { "X-API-Key" => @raw_acme }
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal "pending", body["alert"]["status"]

    queued = ActiveJob::Base.queue_adapter.enqueued_jobs.select do |j|
      (j[:job] || j["job_class"]).to_s == "Alerts::HubDispatchJob"
    end
    assert_equal 1, queued.size
    assert_equal @alert.id, queued.first[:args].first
  end

  test "POST retry on delivered alert returns 409" do
    @alert.update_columns(status: "delivered")
    post "/api/alerts/#{@alert.id}/retry", headers: { "X-API-Key" => @raw_acme }
    assert_response :conflict
  end

  test "POST retry 404s on cross-tenant id" do
    @alert.update_columns(status: "failed")
    post "/api/alerts/#{@alert.id}/retry", headers: { "X-API-Key" => @raw_globex }
    assert_response :not_found
  end

  private

  def create_alert(tenant:, vendor:, score:, status:, new_band: "high")
    RiskAlert.create!(
      tenant: tenant,
      vendor: vendor,
      previous_band: "low",
      new_band: new_band,
      previous_score: 20.0,
      new_score: 65.0,
      direction: "escalation",
      triggered_by_score: score.id,
      status: status,
      delivery_payload: { event_type: "vendor.risk_band_changed", tenant: { id: tenant.id, legal_name: tenant.legal_name } }
    )
  end
end
