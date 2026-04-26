# frozen_string_literal: true

require "test_helper"

# InvoiceReconBackfillJob — PRD §7, §13.2.
#
# Covers:
#   - Happy path: stub InvoiceReconClient with stats → 4 signals per
#     vendor → run.succeeded
#   - Disabled source → :skipped, no run state change
#   - Cursor resume: pre-set retry_payload[cursor] → reads since=cursor
#   - 5xx TransientFailure → run failed, error preserved, re-raised
class Ingestion::InvoiceReconBackfillJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    ensure_signal_catalog
    @vendor = Vendor.create!(
      tenant: @tenant,
      canonical_name: "Acme Vendor Co",
      tax_id: "DE-INV-#{SecureRandom.hex(3)}",
      status: "active"
    )
    @source = create_source!(@tenant)
    install_client_stub!
  end

  teardown do
    Current.tenant = nil
    Ecosystem::InvoiceReconClient.instance = @prev_client_instance if defined?(@prev_client_instance)
  end

  test "happy path — stats ingest 4 signals per vendor, run succeeded" do
    @stub_response = {
      status: :ok, response_code: 200,
      stats: {
        "late_ratio_30d"        => 0.18,
        "dispute_rate_90d"      => 0.05,
        "avg_days_to_pay"       => 17.4,
        "overbilling_rate_30d"  => 0.02
      }
    }

    Ingestion::InvoiceReconBackfillJob.new.perform(@source.id)

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "succeeded", run.status
    assert run.signals_attempted >= 4, "expected ≥ 4 attempted (got #{run.signals_attempted})"
    assert run.signals_stored   >= 4, "expected ≥ 4 stored"
    assert_equal @tenant.id, run.tenant_id

    @source.reload
    assert_not_nil @source.last_successful_pull
    assert_nil     @source.last_failure_reason

    # Cursor advanced
    assert run.retry_payload["cursor"].present?

    # Each of the four signal codes is present.
    %w[invoice.late_ratio_30d invoice.dispute_rate_90d
       invoice.avg_days_to_pay invoice.overbilling_rate_30d].each do |code|
      assert VendorSignal.where(tenant_id: @tenant.id, signal_code: code).exists?,
             "missing signal #{code}"
    end
  end

  test "disabled source — returns :skipped, no run state change" do
    @source.update_columns(is_enabled: false)
    result = Ingestion::InvoiceReconBackfillJob.new.perform(@source.id)
    assert_equal :skipped, result
  end

  test "resumable — uses cursor from retry_payload as :since" do
    cursor_time = Time.utc(2026, 4, 1, 12, 0, 0)
    run = IngestionRun.create!(
      tenant: @tenant, ingestion_source: @source,
      mode: "incremental", status: "running",
      started_at: 1.minute.ago,
      retry_payload: { "cursor" => cursor_time.iso8601 }
    )

    captured_since = nil
    @captured = ->(args) { captured_since = args[:since] }
    @stub_response = {
      status: :ok, response_code: 200,
      stats: { "late_ratio_30d" => 0.1 }
    }

    Ingestion::InvoiceReconBackfillJob.new.perform(@source.id, run.id)

    assert_equal cursor_time.iso8601, captured_since,
                 "expected since=#{cursor_time.iso8601}, got #{captured_since.inspect}"
  end

  test "5xx TransientFailure — run failed, error preserved, raised" do
    @stub_raise = Ecosystem::TransientFailure.new("Invoice Recon returned 503")

    assert_raises(Ecosystem::TransientFailure) do
      Ingestion::InvoiceReconBackfillJob.new.perform(@source.id)
    end

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "failed", run.status
    assert_match(/503|Invoice Recon/, run.error_summary)
  end

  test "tenant scoping — signals stored under source.tenant_id only" do
    @stub_response = {
      status: :ok, response_code: 200,
      stats: { "late_ratio_30d" => 0.1, "dispute_rate_90d" => 0.05 }
    }

    before_ids = VendorSignal.pluck(:id)
    Ingestion::InvoiceReconBackfillJob.new.perform(@source.id)

    new_sigs = VendorSignal.where.not(id: before_ids)
                           .where(source_system: "invoice_recon")
    assert new_sigs.count > 0, "expected newly-ingested signals"
    new_sigs.each { |s| assert_equal @tenant.id, s.tenant_id }
  end

  # ====================================================================
  # Helpers
  # ====================================================================

  private

  def install_client_stub!
    @stub_response = nil
    @stub_raise = nil
    @captured = nil

    test_self = self
    @prev_client_instance = Ecosystem::InvoiceReconClient.instance

    stub = Object.new
    stub.define_singleton_method(:fetch_stats) do |vendor_ref:, since: nil, until_time: nil|
      test_self.instance_variable_get(:@captured)&.call(
        vendor_ref: vendor_ref, since: since, until_time: until_time
      )
      raise test_self.instance_variable_get(:@stub_raise) if test_self.instance_variable_get(:@stub_raise)
      test_self.instance_variable_get(:@stub_response)
    end
    Ecosystem::InvoiceReconClient.instance = stub
  end

  def create_source!(tenant)
    IngestionSource.create!(
      tenant: tenant, source_system: "invoice_recon", is_enabled: true,
      connection_config: { "base_url" => "https://x.example",
                           "api_key_ref" => "ENV:INVOICE_RECON_API_KEY" },
      pull_mode: "periodic"
    )
  end

  def ensure_signal_catalog
    return if SignalDefinition.exists?
    YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each { |row| SignalDefinition.create!(row) }
  end
end
