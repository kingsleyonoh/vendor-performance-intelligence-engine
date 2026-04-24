# frozen_string_literal: true

require "test_helper"

# Tests for ScoreRecomputeJob — PRD §5.4, §7.
# Covers: happy path, no-signals no-op, band-crossing log, tenant scoping,
# bad-tenant error, and the signal_ingester post_insert_hook wiring.
class ScoreRecomputeJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @other = tenants(:globex_inc_us)

    ensure_signal_catalog_seeded
    ensure_rule(@tenant)
    ensure_rule(@other)

    @vendor = Vendor.create!(
      tenant: @tenant,
      canonical_name: "ScoreTest Vendor",
      country_code: "DE",
      status: "active"
    )
  end

  # Swap the active scoring rule so the single financial signal fully
  # drives the composite score — makes band crossings deterministic.
  def rule_for_easy_band_cross
    ScoringRule.where(tenant_id: @tenant.id).update_all(is_active: false)
    ScoringRule.create!(
      tenant_id: @tenant.id,
      name: "Band-Cross Test Rule",
      is_active: true,
      category_weights: {
        "financial" => 1.0, "operational" => 0.0, "contractual" => 0.0,
        "integration" => 0.0, "transactional" => 0.0
      },
      band_thresholds: { "low_max" => 30, "medium_max" => 60, "high_max" => 85 },
      window_days: 90,
      time_decay_half_life_days: 45
    )
  end

  def ensure_signal_catalog_seeded
    return if SignalDefinition.exists?

    yml = YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml"))
    yml.each { |row| SignalDefinition.create!(row) }
  end

  teardown do
    Current.tenant = nil
    ScoreRecomputeJob.band_crossing_hook = ->(_score, _prev) { nil }
  end

  def ensure_rule(tenant)
    ScoringRule.find_or_create_by!(tenant_id: tenant.id, name: "Default v1") do |r|
      r.is_active = true
      r.category_weights = {
        "financial" => 0.35, "operational" => 0.10, "contractual" => 0.30,
        "integration" => 0.10, "transactional" => 0.15
      }
      r.band_thresholds = { "low_max" => 30, "medium_max" => 60, "high_max" => 85 }
      r.window_days = 90
      r.time_decay_half_life_days = 45
    end
  end

  def insert_signal(value: 0.12)
    VendorSignal.create!(
      tenant: @tenant,
      vendor: @vendor,
      signal_code: "invoice.late_ratio_30d",
      source_system: "invoice_recon",
      source_event_id: "srj-#{SecureRandom.hex(4)}",
      value_numeric: value,
      recorded_at: Time.now.utc,
      status: "normalized"
    )
  end

  test "happy path: perform inserts a vendor_scores row" do
    insert_signal
    assert_difference -> { VendorScore.count }, +1 do
      ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)
    end
    score = VendorScore.where(vendor_id: @vendor.id).order(computed_at: :desc).first
    assert_equal @tenant.id, score.tenant_id
  end

  test "no signals: perform returns nil without inserting a score" do
    assert_no_difference -> { VendorScore.count } do
      result = ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)
      assert_nil result
    end
  end

  test "band crossing: logs a 'band_crossing:' line when band changes" do
    # Use a permissive rule so the band transitions are reachable from
    # the small signal set we can generate here (default rule's low_max
    # is 30, which is hard to cross with a single-category signal).
    rule_for_easy_band_cross

    # First score — low band.
    insert_signal(value: 0.05)
    ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)

    # Build up many late signals (high risk) to force a band change.
    8.times { insert_signal(value: 0.95) }

    messages = []
    tagged_logger = Logger.new(
      StringIO.new.tap { |io| io.define_singleton_method(:write) { |s| messages << s; s.bytesize } }
    )

    prev_logger = Rails.logger
    Rails.logger = ActiveSupport::TaggedLogging.new(tagged_logger)
    begin
      ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)
    ensure
      Rails.logger = prev_logger
    end

    crossing_line = messages.find { |m| m.include?("band_crossing:") }
    assert crossing_line, "expected a band_crossing: log line, got #{messages.inspect}"
    assert_match(/from=low/, crossing_line)
  end

  test "tenant binding: Current.tenant is restored (cleared) after perform" do
    Current.tenant = nil
    insert_signal
    ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)
    assert_nil Current.tenant, "expected Current.tenant to be cleared after perform"
  end

  test "invalid tenant_id raises ActiveRecord::RecordNotFound" do
    assert_raises(ActiveRecord::RecordNotFound) do
      ScoreRecomputeJob.new.perform(@vendor.id, SecureRandom.uuid)
    end
  end

  test "post_insert_hook wires ScoreRecomputeJob.perform_later" do
    # The initializer config/initializers/signal_ingester_hooks.rb should
    # have replaced the default no-op hook with a lambda that enqueues.
    hook = Ingestion::SignalIngester.post_insert_hook
    refute_nil hook
    assert_kind_of Proc, hook

    # Exercise: build a signal and call the hook; the :test adapter
    # should record an enqueued ScoreRecomputeJob.
    signal = insert_signal
    prev_adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    begin
      hook.call(signal)
      queued = ActiveJob::Base.queue_adapter.enqueued_jobs
      matching = queued.select { |j| (j[:job] || j["job_class"]).to_s == "ScoreRecomputeJob" }
      assert_equal 1, matching.size,
                   "expected exactly one ScoreRecomputeJob enqueued, got #{queued.inspect}"
    ensure
      ActiveJob::Base.queue_adapter = prev_adapter
    end
  end

  test "band_crossing_hook is called on band change" do
    rule_for_easy_band_cross

    # First score (low).
    insert_signal(value: 0.05)
    ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)

    # Second compute (high).
    8.times { insert_signal(value: 0.95) }
    called_with = nil
    ScoreRecomputeJob.band_crossing_hook = ->(score, prev) { called_with = [score.band, prev] }
    ScoreRecomputeJob.new.perform(@vendor.id, @tenant.id)

    assert called_with, "band_crossing_hook was not called"
    band, prev_band = called_with
    assert_equal "low", prev_band
    refute_equal "low", band, "expected band to change away from low"
  end
end
