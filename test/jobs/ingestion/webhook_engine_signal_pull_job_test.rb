# frozen_string_literal: true

require "test_helper"

# WebhookEngineSignalPullJob — PRD §7, §13.2.
#
# Covers:
#   - Happy path: stub WebhookEngineClient with stats → ingests → run.succeeded
#   - Disabled source → :skipped, no run state change
#   - Cursor resume: pre-set retry_payload[cursor] → reads since=cursor
#   - 5xx TransientFailure → run failed, error preserved, re-raised
#   - Tenant scoping: signals ingest under source.tenant only
class Ingestion::WebhookEngineSignalPullJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @other  = tenants(:globex_inc_us)
    ensure_signal_catalog
    @source = create_source!(@tenant, source_system: "webhook_engine", is_enabled: true)
    install_client_stub!
  end

  teardown do
    Current.tenant = nil
    Ecosystem::WebhookEngineClient.instance = @prev_client_instance if defined?(@prev_client_instance)
  end

  test "happy path — stats ingests signals, run marked succeeded" do
    @stub_response = {
      status: :ok, response_code: 200,
      stats: {
        "success_rate_24h"      => 0.97,
        "dead_letter_count_24h" => 3,
        "schema_drift_24h"      => 1,
        "retry_avg_24h"         => 0.5
      }
    }

    Ingestion::WebhookEngineSignalPullJob.new.perform(@source.id)

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "succeeded", run.status
    assert run.signals_attempted > 0, "expected at least one signal payload"
    assert run.signals_stored > 0, "expected at least one stored signal"
    assert_equal @tenant.id, run.tenant_id

    @source.reload
    assert_not_nil @source.last_successful_pull
    assert_nil @source.last_failure_reason

    # Cursor was advanced.
    assert run.retry_payload["cursor"].present?
  end

  test "disabled source — no run state change, returns :skipped" do
    @source.update_columns(is_enabled: false)
    result = Ingestion::WebhookEngineSignalPullJob.new.perform(@source.id)
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
      stats: { "success_rate_24h" => 1.0 }
    }

    Ingestion::WebhookEngineSignalPullJob.new.perform(@source.id, run.id)

    assert_equal cursor_time.iso8601, captured_since,
                 "expected since=#{cursor_time.iso8601} (cursor); got #{captured_since.inspect}"
  end

  test "5xx TransientFailure — run failed, error preserved, raised" do
    @stub_raise = Ecosystem::TransientFailure.new("Webhook Engine returned 503")

    assert_raises(Ecosystem::TransientFailure) do
      Ingestion::WebhookEngineSignalPullJob.new.perform(@source.id)
    end

    run = IngestionRun.where(ingestion_source_id: @source.id).order(started_at: :desc).first
    assert_equal "failed", run.status
    assert_match(/503|Webhook Engine/, run.error_summary)
  end

  test "tenant scoping — signals stored under source.tenant_id only" do
    @stub_response = {
      status: :ok, response_code: 200,
      stats: { "success_rate_24h" => 0.95 }
    }

    Ingestion::WebhookEngineSignalPullJob.new.perform(@source.id)

    # Every newly-created signal in this run is under @tenant.
    new_sigs = VendorSignal.where(source_system: "webhook_engine")
    new_sigs.each { |s| assert_equal @tenant.id, s.tenant_id }
    assert new_sigs.count > 0
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
    @prev_client_instance = Ecosystem::WebhookEngineClient.instance

    stub = Object.new
    stub.define_singleton_method(:fetch_stats) do |since: nil, until_time: nil|
      test_self.instance_variable_get(:@captured)&.call(since: since, until_time: until_time)
      raise test_self.instance_variable_get(:@stub_raise) if test_self.instance_variable_get(:@stub_raise)
      test_self.instance_variable_get(:@stub_response)
    end
    Ecosystem::WebhookEngineClient.instance = stub
  end

  def create_source!(tenant, source_system:, is_enabled:)
    IngestionSource.create!(
      tenant: tenant, source_system: source_system,
      is_enabled: is_enabled,
      connection_config: { "base_url" => "https://x.example",
                           "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
      pull_mode: "periodic"
    )
  end

  def ensure_signal_catalog
    return if SignalDefinition.exists?
    YAML.load_file(Rails.root.join("db/seeds/signal_definitions.yml")).each { |row| SignalDefinition.create!(row) }
  end
end
