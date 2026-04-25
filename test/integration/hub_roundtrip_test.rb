# frozen_string_literal: true

require "test_helper"
require "openssl"

# End-to-end Hub roundtrip — PRD §13.2 + §15 #12.
#
# Exercises the FULL ecosystem loop in-process:
#
#   1. INBOUND: Hub POSTs to /api/signals/from-hub with HMAC signature
#      → Auth::HubHmacVerifier validates signature
#      → SignalIngester resolves vendor + inserts vendor_signal
#      → ScoreRecomputeJob runs (inline)
#      → CompositeScorer computes a NEW score with band crossing
#      → Alerts::Dispatcher.on_band_crossing fires
#      → Alerts::CapturePayload captures FROZEN snapshot
#      → risk_alerts row inserted with delivery_payload
#      → HubDispatchJob enqueued
#
#   2. OUTBOUND: HubDispatchJob runs (inline)
#      → Ecosystem::HubClient.send_event called with the FROZEN payload
#      → response 200 → status='delivered', hub_event_id stored
#
# This is the canonical proof that:
#   - Phase 1 (signal ingest + scoring) and Phase 2 (alerts + dispatch) link.
#   - Snapshot freezing (PRD §15 #12): a tenant rename between alert creation
#     and HubDispatchJob run does NOT change the dispatched payload.
#   - Idempotency: same source_event_id posted twice → second is deduped,
#     no duplicate alert is emitted.
#   - Workflow escalation: HIGH/CRITICAL band → ALSO triggers
#     WorkflowEscalationJob, which calls WorkflowClient.execute against
#     the SAME frozen payload.
class HubRoundtripTest < ActionDispatch::IntegrationTest
  # Process-global queue_adapter — force sequential so :inline runs without
  # being yanked mid-test by another parallel worker.
  self.use_transactional_tests = true
  parallelize(workers: 1)

  HUB_SECRET = "test-hub-ingress-secret-32bytes!"

  setup do
    @prev_secret = ENV["HUB_INGRESS_SECRET"]
    ENV["HUB_INGRESS_SECRET"] = HUB_SECRET
    @prev_hub_enabled = ENV["NOTIFICATION_HUB_ENABLED"]
    @prev_workflow_enabled = ENV["WORKFLOW_ENGINE_ENABLED"]
    ENV["NOTIFICATION_HUB_ENABLED"] = "true"
    ENV["WORKFLOW_ENGINE_ENABLED"] = "true"

    ensure_signal_catalog_seeded

    @tenant = tenants(:acme_gmbh_de)

    # Fresh vendor with NO prior scores so we can drive a deterministic
    # band crossing low → critical via a single high-impact signal.
    @vendor = Vendor.create!(
      tenant: @tenant,
      canonical_name: "Hub Roundtrip Vendor GmbH",
      country_code: "DE",
      category: "machinery",
      annual_spend_cents: 5_000_000,
      currency: "EUR",
      status: "active"
    )

    # Seed a baseline LOW score so the next recompute crosses bands.
    VendorScore.create!(
      tenant: @tenant,
      vendor: @vendor,
      scoring_rules_id: scoring_rules(:acme_default).id,
      composite_score: 5.0,
      band: "low",
      trend: "stable",
      category_scores: { financial: 5.0, operational: 5.0, contractual: 5.0,
                         integration: 5.0, transactional: 5.0 },
      top_contributors: [],
      window_days: 90,
      signals_considered_count: 1,
      computed_at: 2.hours.ago
    )

    @hub_calls = []
    @workflow_calls = []
    install_hub_stub!
    install_workflow_stub!
  end

  teardown do
    ENV["HUB_INGRESS_SECRET"] = @prev_secret
    ENV["NOTIFICATION_HUB_ENABLED"] = @prev_hub_enabled
    ENV["WORKFLOW_ENGINE_ENABLED"] = @prev_workflow_enabled
    Ecosystem::HubClient.instance = @prev_hub_instance if defined?(@prev_hub_instance)
    Ecosystem::WorkflowClient.instance = @prev_workflow_instance if defined?(@prev_workflow_instance)
    Current.tenant = nil
  end

  def ensure_signal_catalog_seeded
    return if SignalDefinition.exists?
    YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each { |row| SignalDefinition.create!(row) }
  end

  def with_inline_jobs
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  def signed_post(payload)
    body = payload.to_json
    ts = Time.now.to_i
    sig = OpenSSL::HMAC.hexdigest("SHA256", HUB_SECRET, "#{ts}.#{body}")
    post "/api/signals/from-hub",
         params: body,
         headers: {
           "Content-Type" => "application/json",
           "X-VPI-Signature" => "t=#{ts},v1=#{sig}"
         }
  end

  # Seed normalized signals across all four scoring categories at very-high
  # risk values so a fresh recompute lands in HIGH band (>50 composite).
  # All higher_is_worse rates near 1.0 → category score ≈ 100 each →
  # composite ≈ 100 → critical/high.
  def seed_cross_category_high_signals!
    signals = [
      { code: "invoice.dispute_rate_90d",                 value: 0.95 },  # financial
      { code: "contract.sla_miss_ratio_30d",              value: 0.95 },  # contractual
      { code: "webhook.dead_letter_rate_7d",              value: 0.95 },  # integration
      { code: "recon.discrepancy_rate_30d",               value: 0.95 }   # transactional
    ]
    signals.each_with_index do |s, i|
      VendorSignal.create!(
        tenant: @tenant,
        vendor: @vendor,
        signal_code: s[:code],
        source_system: SignalDefinition.find_by(code: s[:code]).source_system,
        source_event_id: "rt-cross-#{i}-#{SecureRandom.hex(2)}",
        value_numeric: s[:value],
        recorded_at: 30.minutes.ago,
        status: "normalized"
      )
    end
  end

  def signal_payload(source_event_id: "roundtrip-evt-#{SecureRandom.hex(4)}", value_numeric: 0.95)
    {
      tenant_slug: @tenant.slug,
      vendor_ref: { normalized_name: @vendor.normalized_name, source_system_ref: "rt-#{@vendor.id[0..7]}" },
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: source_event_id,
      value_numeric: value_numeric,
      recorded_at: 1.hour.ago.iso8601
    }
  end

  # Stub HubClient.instance so the dispatcher's network call captures into
  # @hub_calls instead of hitting the test stubbed adapter — this lets us
  # assert the EXACT payload Ruby-object that was passed (including frozen-
  # ness), not just the wire bytes.
  def install_hub_stub!
    @prev_hub_instance = Ecosystem::HubClient.instance
    test_client = Object.new
    captured = @hub_calls
    test_client.define_singleton_method(:send_event) do |payload|
      captured << payload
      { status: :sent, hub_event_id: "hub-evt-stub-#{captured.size}", response_code: 200 }
    end
    Ecosystem::HubClient.instance = test_client
  end

  def install_workflow_stub!
    @prev_workflow_instance = Ecosystem::WorkflowClient.instance
    test_client = Object.new
    captured = @workflow_calls
    test_client.define_singleton_method(:execute) do |workflow_id:, payload:|
      captured << { workflow_id: workflow_id, payload: payload }
      { status: :executed, execution_id: "wf-exec-stub-#{captured.size}", response_code: 200 }
    end
    Ecosystem::WorkflowClient.instance = test_client
  end

  test "happy path: inbound HMAC POST → band crosses → HubClient called with frozen payload" do
    started_at = Time.now

    with_inline_jobs do
      signed_post(signal_payload)
    end

    elapsed_ms = ((Time.now - started_at) * 1000).round
    assert_response :accepted, response.body

    # Append-only signal landed.
    sig = VendorSignal.where(tenant: @tenant, vendor_id: @vendor.id).order(recorded_at: :desc).first
    assert_not_nil sig, "expected vendor_signal from inbound HMAC post"

    # New score row with band crossed up.
    score = VendorScore.where(tenant: @tenant, vendor_id: @vendor.id)
                       .order(computed_at: :desc).first
    assert_not_nil score
    assert_includes %w[medium high critical], score.band, "band should have crossed up; got #{score.band}"

    # Risk alert created with frozen payload.
    alert = RiskAlert.where(tenant: @tenant, vendor_id: @vendor.id).order(created_at: :desc).first
    assert_not_nil alert, "expected a risk_alert row after band crossing"
    assert_equal "delivered", alert.status
    assert alert.delivery_payload.is_a?(Hash)

    # HubClient was called exactly once with the frozen payload.
    assert_equal 1, @hub_calls.size, "expected exactly one HubClient.send_event call"
    sent_payload = @hub_calls.first
    assert_equal @tenant.legal_name, sent_payload.dig(:tenant, :legal_name) ||
                                     sent_payload.dig("tenant", "legal_name")

    # Performance sanity — full inbound→outbound loop under 3s.
    assert_operator elapsed_ms, :<, 3_000,
                    "Hub roundtrip took #{elapsed_ms}ms — exceeds 3s sanity budget"
  end

  test "snapshot freezing: tenant rename between alert creation and dispatch retry does NOT change dispatched payload" do
    captured_legal_name = @tenant.legal_name

    prev_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear

    # Step 1: post — under :test adapter, ScoreRecomputeJob is captured (not run).
    signed_post(signal_payload)
    assert_response :accepted

    # Step 2: drain ScoreRecomputeJob — that runs the scorer + Alerts::Dispatcher
    # synchronously (since Dispatcher does NOT enqueue another job, it inserts
    # the alert + enqueues HubDispatchJob in-line). The recompute job is the
    # ONLY job we run here — HubDispatchJob remains enqueued for step 4.
    perform_enqueued_jobs only: ScoreRecomputeJob

    alert = RiskAlert.where(tenant: @tenant, vendor_id: @vendor.id).order(created_at: :desc).first
    assert_not_nil alert, "expected risk_alert after recompute job"
    assert_equal "pending", alert.status
    assert_equal captured_legal_name, alert.delivery_payload.dig("tenant", "legal_name")

    # Step 3: rename the tenant AFTER alert creation but BEFORE dispatch.
    @tenant.update_columns(legal_name: "RENAMED After Alert", display_name: "RENAMED")

    # Step 4: now dispatch.
    perform_enqueued_jobs only: Alerts::HubDispatchJob

    # Outbound payload MUST contain the OLD legal_name, not the renamed one.
    assert_equal 1, @hub_calls.size
    sent_legal = @hub_calls.first.dig(:tenant, :legal_name) ||
                 @hub_calls.first.dig("tenant", "legal_name")
    assert_equal captured_legal_name, sent_legal,
                 "snapshot-freezing violation: dispatched payload reflects post-creation rename"
    refute_includes sent_legal.to_s, "RENAMED",
                    "TENANT_IDENTITY_LEAK: dispatched payload contains renamed tenant value"
  ensure
    ActiveJob::Base.queue_adapter = prev_adapter if prev_adapter
  end

  test "idempotency: same source_event_id posted twice → second is deduped (no duplicate alert)" do
    payload = signal_payload(source_event_id: "duplicate-roundtrip-evt")

    with_inline_jobs do
      signed_post(payload)
    end
    assert_response :accepted
    first_alert_count = RiskAlert.where(tenant: @tenant, vendor_id: @vendor.id).count

    @hub_calls.clear
    with_inline_jobs do
      signed_post(payload) # same source_event_id
    end
    body = JSON.parse(response.body)
    assert_equal "deduped", body["status"], "second post with same source_event_id must dedup"

    # No new alert row.
    assert_equal first_alert_count,
                 RiskAlert.where(tenant: @tenant, vendor_id: @vendor.id).count,
                 "duplicate inbound must not create additional alerts"

    # No additional Hub call.
    assert_equal 0, @hub_calls.size, "duplicate inbound must not re-trigger Hub dispatch"
  end

  test "high band: WorkflowClient.execute called alongside HubClient" do
    # Seed signals across all four categories at very high risk values so
    # the recompute lands solidly in HIGH (>50). One financial signal
    # alone only contributes ~35 to the composite (35% category weight).
    seed_cross_category_high_signals!

    with_inline_jobs do
      signed_post(signal_payload(value_numeric: 0.99))
    end
    assert_response :accepted

    score = VendorScore.where(tenant: @tenant, vendor_id: @vendor.id).order(computed_at: :desc).first
    assert_includes %w[high critical], score.band,
                    "fixture must drive HIGH or CRITICAL for escalation; got #{score.band}"

    alert = RiskAlert.where(tenant: @tenant, vendor_id: @vendor.id).order(created_at: :desc).first
    assert_not_nil alert

    assert_equal 1, @hub_calls.size, "Hub dispatch must fire once"
    assert_equal 1, @workflow_calls.size,
                 "Workflow escalation must fire for HIGH/CRITICAL band"

    wf_call = @workflow_calls.first
    assert_equal "vpi-risk-escalation-default", wf_call[:workflow_id]
    # Workflow payload must derive from the SAME frozen alert payload.
    assert_equal @tenant.legal_name,
                 wf_call.dig(:payload, :tenant, "legal_name") ||
                 wf_call.dig(:payload, :tenant, :legal_name)
  end
end
