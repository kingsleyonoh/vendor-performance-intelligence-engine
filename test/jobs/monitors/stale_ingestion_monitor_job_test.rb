# frozen_string_literal: true

require "test_helper"

# Monitors::StaleIngestionMonitorJob — PRD §7b, §13.2.
#
# Hourly cron that detects ingestion sources where last_successful_pull
# is older than 24h and emits a Hub event `vpi-ingestion-stale`. Idempotent
# within a 6h window per source via `ingestion_sources.monitor_state.last_stale_emitted_at`.
#
# Standalone-first: when Notification Hub is disabled, the monitor still
# runs but logs a warning and skips the HTTP call (no alert flooding).
module Monitors; end unless defined?(Monitors)

class Monitors::StaleIngestionMonitorJobTest < ActiveJob::TestCase
  setup do
    @tenant = tenants(:acme_gmbh_de)
    @other  = tenants(:globex_inc_us)
    install_hub_stub!
  end

  teardown do
    Current.tenant = nil
    Ecosystem::HubClient.instance = @prev_hub_instance if defined?(@prev_hub_instance)
  end

  test "stale source older than 24h — emits Hub event + records snapshot" do
    src = stale_source!(tenant: @tenant, last_pull: 30.hours.ago)

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 1, @sent_payloads.length, "expected 1 Hub event"
    payload = @sent_payloads.first
    assert_equal "ingestion.source_stale", payload[:event_type]
    assert_equal @tenant.id, payload[:tenant][:id]
    assert_equal src.id, payload[:source][:id]
    assert_equal "webhook_engine", payload[:source][:source_system]
    assert payload[:source][:hours_stale] >= 24

    src.reload
    assert src.monitor_state["last_stale_emitted_at"].present?,
           "expected monitor_state.last_stale_emitted_at to be recorded"
  end

  test "source pulled <24h ago — no emit" do
    fresh_source!(tenant: @tenant, last_pull: 5.hours.ago)

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 0, @sent_payloads.length
  end

  test "source never pulled but freshly created (<24h) — no emit" do
    src = IngestionSource.create!(
      tenant: @tenant, source_system: "invoice_recon", is_enabled: true,
      connection_config: { "api_key_ref" => "ENV:INVOICE_RECON_API_KEY" },
      pull_mode: "periodic",
      created_at: 1.hour.ago, updated_at: 1.hour.ago
    )

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 0, @sent_payloads.length, "freshly-onboarded source should not alert"
    src.reload
    refute src.monitor_state["last_stale_emitted_at"].present?
  end

  test "source never pulled and >24h old — emits" do
    IngestionSource.create!(
      tenant: @tenant, source_system: "contract_engine", is_enabled: true,
      connection_config: { "api_key_ref" => "ENV:CONTRACT_ENGINE_API_KEY" },
      pull_mode: "periodic",
      created_at: 30.hours.ago, updated_at: 30.hours.ago
    )

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 1, @sent_payloads.length
    assert_equal "contract_engine", @sent_payloads.first[:source][:source_system]
  end

  test "idempotent — already emitted within 6h, no re-emit" do
    src = stale_source!(tenant: @tenant, last_pull: 30.hours.ago)
    src.update_columns(monitor_state: { "last_stale_emitted_at" => 2.hours.ago.utc.iso8601 })

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 0, @sent_payloads.length, "should be silenced by 6h dedup window"
  end

  test "re-emits after 6h cooldown elapses" do
    src = stale_source!(tenant: @tenant, last_pull: 30.hours.ago)
    src.update_columns(monitor_state: { "last_stale_emitted_at" => 7.hours.ago.utc.iso8601 })

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 1, @sent_payloads.length, "should re-emit after 6h"
  end

  test "Hub disabled — detects stale, logs warning, no HTTP call" do
    src = stale_source!(tenant: @tenant, last_pull: 30.hours.ago)

    # Hub disabled means HubClient.send_event returns :skipped — no payloads sent.
    Monitors::StaleIngestionMonitorJob.new.perform

    assert_equal 0, @sent_payloads.length
    src.reload
    # In Hub-disabled mode we DO NOT update monitor_state (so when Hub
    # comes back online the next run can emit).
    refute src.monitor_state["last_stale_emitted_at"].present?
  end

  test "disabled source — never alerts even if stale" do
    IngestionSource.create!(
      tenant: @tenant, source_system: "rag_platform", is_enabled: false,
      connection_config: {}, pull_mode: "periodic",
      last_successful_pull: 30.hours.ago, last_attempted_pull: 30.hours.ago,
      created_at: 30.hours.ago, updated_at: 30.hours.ago
    )

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 0, @sent_payloads.length
  end

  test "tenant snapshot is captured per source's tenant" do
    stale_source!(tenant: @tenant, last_pull: 30.hours.ago)
    stale_source!(tenant: @other, last_pull: 30.hours.ago, source_system: "invoice_recon")

    with_hub_enabled do
      Monitors::StaleIngestionMonitorJob.new.perform
    end

    assert_equal 2, @sent_payloads.length

    acme_payload   = @sent_payloads.find { |p| p[:tenant][:id] == @tenant.id }
    globex_payload = @sent_payloads.find { |p| p[:tenant][:id] == @other.id }

    assert acme_payload, "acme payload missing"
    assert globex_payload, "globex payload missing"

    # Cross-tenant snapshot integrity (PRD §4.T identity columns).
    assert_equal "Acme",   acme_payload[:tenant][:display_name]
    assert_equal "Globex", globex_payload[:tenant][:display_name]
    refute_includes acme_payload.to_json,   "Globex"
    refute_includes globex_payload.to_json, "Acme"
  end

  # ====================================================================
  # Helpers
  # ====================================================================

  private

  def install_hub_stub!
    @sent_payloads = []
    @prev_hub_instance = Ecosystem::HubClient.instance

    test_self = self
    stub = Object.new
    stub.define_singleton_method(:enabled?) do
      ENV.fetch("NOTIFICATION_HUB_ENABLED", "false").to_s.downcase == "true"
    end
    stub.define_singleton_method(:send_event) do |payload|
      if ENV.fetch("NOTIFICATION_HUB_ENABLED", "false").to_s.downcase != "true"
        next { status: :skipped, reason: "Hub disabled" }
      end
      test_self.instance_variable_get(:@sent_payloads) << payload
      { status: :sent, hub_event_id: "hub-evt-#{SecureRandom.hex(4)}", response_code: 202 }
    end
    Ecosystem::HubClient.instance = stub
  end

  def with_hub_enabled
    prev = ENV["NOTIFICATION_HUB_ENABLED"]
    ENV["NOTIFICATION_HUB_ENABLED"] = "true"
    yield
  ensure
    ENV["NOTIFICATION_HUB_ENABLED"] = prev
  end

  def stale_source!(tenant:, last_pull:, source_system: "webhook_engine")
    IngestionSource.create!(
      tenant: tenant, source_system: source_system, is_enabled: true,
      connection_config: { "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
      pull_mode: "periodic",
      last_successful_pull: last_pull, last_attempted_pull: last_pull,
      last_failure_reason: nil,
      created_at: last_pull, updated_at: last_pull
    )
  end

  def fresh_source!(tenant:, last_pull:)
    IngestionSource.create!(
      tenant: tenant, source_system: "webhook_engine", is_enabled: true,
      connection_config: { "api_key_ref" => "ENV:WEBHOOK_ENGINE_API_KEY" },
      pull_mode: "periodic",
      last_successful_pull: last_pull, last_attempted_pull: last_pull,
      created_at: 2.days.ago, updated_at: last_pull
    )
  end
end
