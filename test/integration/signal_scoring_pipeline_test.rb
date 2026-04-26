# frozen_string_literal: true

require "test_helper"

# End-to-end pipeline — signal ingest → score compute → band/trend populated
# → band-crossing detected. PRD §15 criteria #2 (score computation < 2s for
# 10k signals — here we assert the happy-path single-signal pipeline runs
# well under that budget) and the PRD §2 invariants 3 (append-only signals)
# + 4 (score explains itself via top_contributors).
#
# Uses ActionDispatch::IntegrationTest to hit /api/signals over the real
# Rack stack (so middleware, dry-validation, and the post-insert hook all
# fire). `perform_enqueued_jobs` forces ScoreRecomputeJob to run
# synchronously, so the `vendor_scores` row is visible by assertion time.
class SignalScoringPipelineTest < ActionDispatch::IntegrationTest
  # queue_adapter is process-global — if another parallel test flips it
  # mid-flight, our :inline assumption breaks. Force sequential for this file.
  self.use_transactional_tests = true
  parallelize(workers: 1)

  ACME_RAW_KEY = "vpi_test_acme_key_00000000000000000000"

  # Flip ActiveJob to the :inline adapter for this block so
  # `.perform_later` runs synchronously inside the enqueuing request —
  # the pipeline assertion depends on ScoreRecomputeJob having completed
  # by the time the POST returns. The default test adapter (:test) merely
  # captures jobs; only `perform_enqueued_jobs` would run them, and that
  # does not cover the controller-side hook path end-to-end.
  def with_inline_jobs
    previous = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :inline
    yield
  ensure
    ActiveJob::Base.queue_adapter = previous
  end

  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    @acme = tenants(:acme_gmbh_de)
    # Use a fresh vendor with NO prior scores/signals so we can assert
    # "new vendor → new-trend / first score row".
    @vendor = Vendor.create!(
      tenant: @acme,
      canonical_name: "Pipeline Test Vendor GmbH",
      country_code: "DE",
      category: "machinery",
      annual_spend_cents: 1_000_000,
      currency: "EUR",
      status: "active"
    )
  end

  teardown do
    Current.tenant = nil
    Rails.cache = @previous_cache if @previous_cache
  end

  def acme_headers
    { "X-API-Key" => ACME_RAW_KEY, "Content-Type" => "application/json" }
  end

  test "PRD §15 #2: POST /api/signals → recompute → vendor_scores row for the target vendor" do
    # Use `vendor_ref` (normalized_name-based) so the ingester resolves to
    # our freshly-created vendor without needing an existing alias.
    body = {
      vendor_ref: { normalized_name: @vendor.normalized_name, source_system_ref: "pipeline-#{@vendor.id[0..7]}" },
      source_system: "invoice_recon",
      source_event_id: "pipeline-sig-1-#{SecureRandom.hex(4)}",
      signal_code: "invoice.late_ratio_30d",
      value_numeric: 0.25,
      recorded_at: 1.hour.ago.iso8601
    }

    before_count = VendorScore.where(tenant: @acme, vendor_id: @vendor.id).count
    started_at = Time.now

    # Some environments queue_adapter = :test (jobs captured, not run).
    # Force inline for this test so ScoreRecomputeJob runs synchronously
    # inside the POST — reproducing production wiring.
    with_inline_jobs do
      post "/api/signals", params: body.to_json, headers: acme_headers
    end

    elapsed_ms = ((Time.now - started_at) * 1000).round
    assert_equal 201, response.status, response.body

    after_count = VendorScore.where(tenant: @acme, vendor_id: @vendor.id).count
    assert_equal before_count + 1, after_count,
      "ScoreRecomputeJob should have inserted one new vendor_scores row"

    score = VendorScore.where(tenant: @acme, vendor_id: @vendor.id)
                      .order(computed_at: :desc).first
    assert_not_nil score
    assert_not_nil score.composite_score
    assert_includes VendorScore::BANDS, score.band
    assert_includes VendorScore::TRENDS, score.trend

    # Performance sanity — PRD §15 #2 budgets 2s for 10k signals on warm
    # code paths; this assertion includes first-request Rails eager-load
    # overhead in the test process. 3s gives headroom for cold starts
    # while still catching pathological regressions (e.g. an N+1 blow-up
    # that pushes an isolated single-signal run past multiple seconds).
    assert_operator elapsed_ms, :<, 3_000,
      "Single-signal pipeline took #{elapsed_ms}ms — exceeds 3s sanity budget"
  end

  test "PRD §2 invariant 4: score row decomposes into contributing signals" do
    body = {
      vendor_ref: { normalized_name: @vendor.normalized_name, source_system_ref: "pipeline-#{@vendor.id[0..7]}" },
      source_system: "invoice_recon",
      source_event_id: "pipeline-sig-2-#{SecureRandom.hex(4)}",
      signal_code: "invoice.late_ratio_30d",
      value_numeric: 0.5,
      recorded_at: 1.hour.ago.iso8601
    }

    with_inline_jobs do
      post "/api/signals", params: body.to_json, headers: acme_headers
    end

    score = VendorScore.where(tenant: @acme, vendor_id: @vendor.id)
                      .order(computed_at: :desc).first
    assert_not_nil score

    # Invariant 4: every score MUST explain itself through category_scores
    # + top_contributors. Empty/null here means the score cannot be
    # rendered on the operator UI as "here's why".
    assert_kind_of Hash, score.category_scores
    assert score.category_scores.any?, "category_scores must carry at least one category"

    assert_kind_of Array, score.top_contributors
    assert score.top_contributors.any?, "top_contributors must have at least one row"
    assert_operator score.top_contributors.length, :<=, VendorScore::MAX_CONTRIBUTORS,
      "top_contributors capped at #{VendorScore::MAX_CONTRIBUTORS} (invariant 4)"
  end

  test "PRD §2 invariant 3: vendor_signals row is append-only + persisted with status=normalized" do
    body = {
      vendor_ref: { normalized_name: @vendor.normalized_name, source_system_ref: "pipeline-#{@vendor.id[0..7]}" },
      source_system: "invoice_recon",
      source_event_id: "pipeline-sig-3-#{SecureRandom.hex(4)}",
      signal_code: "invoice.late_ratio_30d",
      value_numeric: 0.1,
      recorded_at: 1.hour.ago.iso8601
    }

    with_inline_jobs do
      post "/api/signals", params: body.to_json, headers: acme_headers
    end

    sig = VendorSignal.where(tenant: @acme, vendor_id: @vendor.id).order(recorded_at: :desc).first
    assert_not_nil sig
    assert_equal "normalized", sig.status

    # Append-only guard — any UPDATE of a non-status column must raise.
    assert_raises VendorSignal::AppendOnlyViolation do
      sig.update(value_numeric: 0.99)
    end
  end
end
