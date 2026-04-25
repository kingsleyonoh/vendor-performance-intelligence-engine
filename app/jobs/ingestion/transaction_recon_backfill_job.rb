# frozen_string_literal: true

module Ingestion
  # TransactionReconBackfillJob — PRD §7, §13.2.
  #
  # Two trigger paths (mirrors InvoiceReconBackfillJob):
  #   1. Sidekiq cron — every 15 min, iterates over enabled recon_engine
  #      sources for ALL tenants (no args).
  #   2. Pull-now controller — explicit per-source manual trigger with a
  #      pre-created `ingestion_run_id`.
  #
  # Pipeline (per source):
  #   - Skip disabled sources (PRD §2.2 standalone-first).
  #   - Reuse pre-created run when called from pull-now; otherwise create one.
  #   - Read resumable `cursor` from `run.retry_payload["cursor"]`; fall
  #     back to `source.last_successful_pull`.
  #   - For each active vendor on the source's tenant: call
  #     `Ecosystem::ReconEngineClient.fetch_stats(vendor_ref:, since:, until_time:)`.
  #   - Map stats → signal payloads via `Ingestion::Mappers::ReconEngineMapper`.
  #   - Each payload → `Ingestion::SignalIngester.call(payload, tenant)`.
  #   - Track attempted / stored / rejected / deduped on the run.
  #   - On TransientFailure / CircuitOpen: status='failed', cursor preserved,
  #     re-raise so Sidekiq retries.
  class TransactionReconBackfillJob < ApplicationJob
    queue_as :default

    # Cron-mode entry: no args → iterate enabled recon_engine sources for
    # every tenant. Single-source variant: source_id (+ optional run_id).
    def perform(source_id = nil, ingestion_run_id = nil)
      if source_id.nil?
        cron_iterate
      else
        run_for_source(source_id, ingestion_run_id)
      end
    end

    private

    def cron_iterate
      IngestionSource
        .where(source_system: "recon_engine", is_enabled: true)
        .find_each do |source|
          self.class.perform_later(source.id)
        rescue StandardError => e
          Rails.logger.error("[recon_engine_pull] failed to enqueue source=#{source.id}: #{e.class}: #{e.message}")
        end
    end

    def run_for_source(source_id, ingestion_run_id)
      source = IngestionSource.find(source_id)
      unless source.is_enabled
        Rails.logger.tagged("ingestion.recon_engine") do
          Rails.logger.info("source=#{source_id} disabled — skip")
        end
        return :skipped
      end

      run = ingestion_run_id ?
        IngestionRun.find(ingestion_run_id) :
        IngestionRun.create!(
          tenant_id: source.tenant_id,
          ingestion_source_id: source.id,
          mode: "incremental",
          status: "running",
          started_at: Time.now.utc
        )

      execute_pull!(source: source, run: run)
    rescue Ecosystem::TransientFailure, Ecosystem::CircuitOpen => e
      mark_failed!(run, error: e.message) if defined?(run) && run
      raise # let Sidekiq re-queue per its retry policy
    end

    def execute_pull!(source:, run:)
      cursor = parse_cursor((run.retry_payload || {})["cursor"]) || source.last_successful_pull
      until_time = Time.now.utc

      attempted = stored = rejected = deduped = 0
      had_failure = false

      vendors_for(source).each do |vendor|
        response = client.fetch_stats(
          vendor_ref: vendor_ref_for(vendor),
          since: cursor&.iso8601,
          until_time: until_time.iso8601
        )

        case response[:status]
        when :skipped
          # Standalone-first short-circuit — first vendor's :skipped means
          # the integration is feature-flagged off. Stop iterating and
          # treat the run as a successful no-op.
          mark_succeeded!(run, source: source, cursor: until_time,
                          attempted: 0, stored: 0, rejected: 0, deduped: 0)
          return run
        when :failed
          had_failure = true
          mark_failed!(run, error: "Recon Engine returned #{response[:response_code]}: #{response[:error]}")
          return run
        when :ok
          a, s, r, d = ingest_stats!(run: run, source: source, vendor: vendor,
                                     stats: response[:stats], recorded_at: until_time)
          attempted += a; stored += s; rejected += r; deduped += d
        end
      end

      return run if had_failure
      mark_succeeded!(run, source: source, cursor: until_time,
                      attempted: attempted, stored: stored,
                      rejected: rejected, deduped: deduped)
      run
    end

    def vendors_for(source)
      Vendor.where(tenant_id: source.tenant_id, status: "active")
    end

    def vendor_ref_for(vendor)
      vendor.tax_id.presence || vendor.normalized_name.presence || vendor.id.to_s
    end

    def ingest_stats!(run:, source:, vendor:, stats:, recorded_at:)
      payloads = Ingestion::Mappers::ReconEngineMapper.map_stats(
        stats: stats, source: source, vendor: vendor, recorded_at: recorded_at
      )

      attempted = stored = rejected = deduped = 0
      tenant = source.tenant
      payloads.each do |payload|
        attempted += 1
        result = Ingestion::SignalIngester.call(payload: payload, tenant: tenant)
        case result[:status]
        when :ingested then stored += 1
        when :deduped  then deduped += 1
        when :rejected then rejected += 1
        end
      rescue StandardError => e
        rejected += 1
        Rails.logger.error("[recon_engine_pull] ingest error: #{e.class}: #{e.message}")
      end

      run.update_columns(
        signals_attempted: (run.signals_attempted || 0) + attempted,
        signals_stored:    (run.signals_stored    || 0) + stored,
        signals_rejected:  (run.signals_rejected  || 0) + rejected,
        signals_deduped:   (run.signals_deduped   || 0) + deduped,
        updated_at: Time.now.utc
      )

      [attempted, stored, rejected, deduped]
    end

    def mark_succeeded!(run, source:, cursor:, attempted:, stored:, rejected:, deduped:)
      run.update_columns(
        status: "succeeded",
        signals_attempted: attempted,
        signals_stored: stored,
        signals_rejected: rejected,
        signals_deduped: deduped,
        retry_payload: (run.retry_payload || {}).merge("cursor" => cursor.iso8601),
        finished_at: Time.now.utc,
        updated_at: Time.now.utc
      )
      source.update_columns(
        last_successful_pull: cursor,
        last_attempted_pull: Time.now.utc,
        last_failure_reason: nil,
        updated_at: Time.now.utc
      )
    end

    def mark_failed!(run, error:)
      run.update_columns(
        status: "failed",
        error_summary: error.to_s[0, 1000],
        finished_at: Time.now.utc,
        updated_at: Time.now.utc
      )
      run.ingestion_source.update_columns(
        last_attempted_pull: Time.now.utc,
        last_failure_reason: error.to_s[0, 500],
        updated_at: Time.now.utc
      )
    end

    def client
      Ecosystem::ReconEngineClient.instance || Ecosystem::ReconEngineClient.new
    end

    def parse_cursor(value)
      return nil if value.nil?
      return value if value.is_a?(Time)
      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end
  end
end
