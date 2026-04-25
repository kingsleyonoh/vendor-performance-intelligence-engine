# frozen_string_literal: true

require "test_helper"

# ContractLifecycleBackfillJob — PRD §7, §13.2.
#
# REST catch-up complement to the NATS consumer. Mirrors
# InvoiceReconBackfillJob shape (cursor / pull / map / ingest).
#
# Tests stub `Ecosystem::ContractEngineClient.instance` to a test double.
class Ingestion::ContractLifecycleBackfillJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    ensure_signal_catalog
    @vendor = Vendor.create!(
      tenant: @tenant,
      canonical_name: "Acme Contract Co",
      tax_id: "DE-CONTRACTBF-#{SecureRandom.hex(3)}",
      status: "active"
    )
    @source = create_source!(@tenant)
    install_client_stub!
  end

  teardown do
    Current.tenant = nil
    Ecosystem::ContractEngineClient.instance = @prev_client_instance if defined?(@prev_client_instance)
  end

  test "happy path — stats ingest signals per vendor, run succeeded" do
    @stub_response = {
      status: :ok, response_code: 200,
      stats: {
        "obligation_breach_count_90d"        => 4,
        "sla_miss_ratio_30d"                 => 0.18,
        "renewal_risk_level"                 => 2,
        "auto_renewal_flag"                  => true,
        "obligation_deadline_missed_count_30d" => 1
      }
    }

    Ingestion::ContractLifecycleBackfillJob.new.perform(@source.id)

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "succeeded", run.status
    assert run.signals_attempted >= 5, "expected ≥ 5 attempted (got #{run.signals_attempted})"
    assert run.signals_stored   >= 5, "expected ≥ 5 stored"
    assert_equal @tenant.id, run.tenant_id

    @source.reload
    assert_not_nil @source.last_successful_pull
    assert_nil     @source.last_failure_reason
    assert run.retry_payload["cursor"].present?

    %w[
      contract.obligation_breach_count_90d
      contract.sla_miss_ratio_30d
      contract.renewal_at_risk
      contract.auto_renewal_flag
      contract.obligation_deadline_missed_count_30d
    ].each do |code|
      assert VendorSignal.where(tenant_id: @tenant.id, signal_code: code).exists?,
             "missing signal #{code}"
    end
  end

  test "disabled source — returns :skipped, no run state change" do
    @source.update_columns(is_enabled: false)
    result = Ingestion::ContractLifecycleBackfillJob.new.perform(@source.id)
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
      stats: { "obligation_breach_count_90d" => 1 }
    }

    Ingestion::ContractLifecycleBackfillJob.new.perform(@source.id, run.id)

    assert_equal cursor_time.iso8601, captured_since,
                 "expected since=#{cursor_time.iso8601}, got #{captured_since.inspect}"
  end

  test "5xx TransientFailure — run failed, error preserved, raised" do
    @stub_raise = Ecosystem::TransientFailure.new("Contract Engine returned 503")

    assert_raises(Ecosystem::TransientFailure) do
      Ingestion::ContractLifecycleBackfillJob.new.perform(@source.id)
    end

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "failed", run.status
    assert_match(/503|Contract Engine/, run.error_summary)
  end

  test "skipped from client (feature-flag off upstream) — short-circuits to no-op success" do
    @stub_response = { status: :skipped, reason: "Contract Engine disabled" }

    Ingestion::ContractLifecycleBackfillJob.new.perform(@source.id)

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "succeeded", run.status
    assert_equal 0, run.signals_attempted.to_i
    assert_equal 0, run.signals_stored.to_i
  end

  test "tenant scoping — signals stored under source.tenant_id only" do
    @stub_response = {
      status: :ok, response_code: 200,
      stats: { "obligation_breach_count_90d" => 2, "sla_miss_ratio_30d" => 0.05 }
    }

    before_ids = VendorSignal.pluck(:id)
    Ingestion::ContractLifecycleBackfillJob.new.perform(@source.id)

    new_sigs = VendorSignal.where.not(id: before_ids)
                           .where(source_system: "contract_engine")
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
    @prev_client_instance = Ecosystem::ContractEngineClient.instance

    stub = Object.new
    stub.define_singleton_method(:fetch_stats) do |vendor_ref:, since: nil, until_time: nil|
      test_self.instance_variable_get(:@captured)&.call(
        vendor_ref: vendor_ref, since: since, until_time: until_time
      )
      raise test_self.instance_variable_get(:@stub_raise) if test_self.instance_variable_get(:@stub_raise)
      test_self.instance_variable_get(:@stub_response)
    end
    Ecosystem::ContractEngineClient.instance = stub
  end

  def create_source!(tenant)
    IngestionSource.create!(
      tenant: tenant, source_system: "contract_engine", is_enabled: true,
      connection_config: { "base_url" => "https://x.example",
                           "api_key_ref" => "ENV:CONTRACT_ENGINE_API_KEY" },
      pull_mode: "periodic"
    )
  end

  def ensure_signal_catalog
    return if SignalDefinition.exists?
    YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each { |row| SignalDefinition.create!(row) }
  end
end
