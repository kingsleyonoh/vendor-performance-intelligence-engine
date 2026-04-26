# frozen_string_literal: true

require "test_helper"

# IngestionRun — PRD §4. One row per ingestion attempt (full backfill,
# incremental pull, webhook event, manual trigger). Tracks
# attempted/stored/rejected/deduped counts plus a resumable cursor in
# `retry_payload`.
class IngestionRunTest < ActiveSupport::TestCase
  setup do
    @acme   = tenants(:acme_gmbh_de)
    @globex = tenants(:globex_inc_us)
    @acme_source = IngestionSource.create!(
      tenant: @acme, source_system: "invoice_recon", pull_mode: "periodic", is_enabled: true
    )
    @globex_source = IngestionSource.create!(
      tenant: @globex, source_system: "invoice_recon", pull_mode: "periodic", is_enabled: true
    )
  end

  test "creates with required attributes" do
    run = IngestionRun.create!(
      tenant: @acme,
      ingestion_source: @acme_source,
      mode: "incremental",
      status: "running",
      started_at: Time.now.utc
    )

    assert run.persisted?
    assert_equal 0, run.signals_attempted
    assert_equal 0, run.signals_stored
    assert_equal({}, run.retry_payload)
  end

  test "tenant scoping — runs are isolated per tenant" do
    IngestionRun.create!(tenant: @acme, ingestion_source: @acme_source,
                         mode: "incremental", status: "running", started_at: Time.now.utc)
    IngestionRun.create!(tenant: @globex, ingestion_source: @globex_source,
                         mode: "incremental", status: "running", started_at: Time.now.utc)

    assert_equal 1, IngestionRun.where(tenant_id: @acme.id).count
    assert_equal 1, IngestionRun.where(tenant_id: @globex.id).count
  end

  test "rejects unknown mode" do
    run = IngestionRun.new(tenant: @acme, ingestion_source: @acme_source,
                           mode: "telepathy", status: "running", started_at: Time.now.utc)
    refute run.valid?
    assert_includes run.errors[:mode], "is not included in the list"
  end

  test "rejects unknown status" do
    run = IngestionRun.new(tenant: @acme, ingestion_source: @acme_source,
                           mode: "incremental", status: "imploding", started_at: Time.now.utc)
    refute run.valid?
  end

  test "retry_payload stores resumable cursor" do
    run = IngestionRun.create!(
      tenant: @acme,
      ingestion_source: @acme_source,
      mode: "full_backfill",
      status: "running",
      started_at: Time.now.utc,
      retry_payload: { cursor: "next-page-token-abc", page_index: 4 }
    )
    run.reload
    assert_equal "next-page-token-abc", run.retry_payload["cursor"]
    assert_equal 4, run.retry_payload["page_index"]
  end

  test "ingestion_source association tied to tenant FK" do
    run = IngestionRun.create!(
      tenant: @acme, ingestion_source: @acme_source,
      mode: "incremental", status: "running", started_at: Time.now.utc
    )
    assert_equal @acme_source.id, run.ingestion_source.id
  end

  test "status terminal values populate finished_at + counts" do
    run = IngestionRun.create!(
      tenant: @acme, ingestion_source: @acme_source,
      mode: "incremental", status: "running", started_at: 5.minutes.ago
    )
    run.update!(status: "succeeded", signals_attempted: 100, signals_stored: 95,
                signals_rejected: 3, signals_deduped: 2, finished_at: Time.now.utc)

    assert_equal "succeeded", run.status
    assert_equal 100, run.signals_attempted
    assert_not_nil run.finished_at
  end
end
