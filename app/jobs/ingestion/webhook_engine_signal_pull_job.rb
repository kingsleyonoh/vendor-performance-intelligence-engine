# frozen_string_literal: true

module Ingestion
  # WebhookEngineSignalPullJob — PRD §7, §13.2.
  #
  # Two trigger paths:
  #   1. Sidekiq cron — every 10 min, iterates over enabled webhook_engine
  #      sources for ALL tenants (no args).
  #   2. Pull-now controller — explicit per-source manual trigger with a
  #      pre-created `ingestion_run_id`.
  #
  # Pipeline:
  #   - Skip disabled sources (PRD §2.2 standalone-first).
  #   - Reuse pre-created run when called from pull-now; otherwise create one.
  #   - Read resumable `cursor` from `run.retry_payload["cursor"]` if present;
  #     else fall back to `source.last_successful_pull`.
  #   - Call `Ecosystem::WebhookEngineClient.fetch_stats(since:, until:)`.
  #   - Map stats → signal payloads via `Ingestion::Mappers::WebhookEngineMapper`.
  #   - Each payload → `Ingestion::SignalIngester.call(payload, tenant)`.
  #   - Track attempted / stored / rejected / deduped counters on the run.
  #   - On success: status='succeeded', source.last_successful_pull updated,
  #     cursor advanced to the run window's `until_time`.
  #   - On TransientFailure / CircuitOpen: status='failed', cursor preserved,
  #     re-raise so Sidekiq retries.
  #   - On terminal :failed from the client: status='failed', no retry.
  class WebhookEngineSignalPullJob < ApplicationJob
    queue_as :default

    # Cron-mode entry: no args → iterate enabled webhook_engine sources for
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
        .where(source_system: "webhook_engine", is_enabled: true)
        .find_each do |source|
          self.class.perform_later(source.id)
        rescue StandardError => e
          Rails.logger.error("[webhook_engine_pull] failed to enqueue source=#{source.id}: #{e.class}: #{e.message}")
        end
    end

    def run_for_source(source_id, ingestion_run_id)
      source = IngestionSource.find(source_id)
      unless source.is_enabled
        Rails.logger.tagged("ingestion.webhook_engine") do
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

      response = client.fetch_stats(
        since: cursor&.iso8601,
        until_time: until_time.iso8601
      )

      case response[:status]
      when :skipped
        mark_succeeded!(run, source: source, cursor: until_time, attempted: 0,
                        stored: 0, rejected: 0, deduped: 0)
      when :failed
        mark_failed!(run, error: "Webhook Engine returned #{response[:response_code]}: #{response[:error]}")
      when :ok
        ingest_stats!(run: run, source: source, stats: response[:stats], recorded_at: until_time)
        mark_succeeded!(run, source: source, cursor: until_time, **run_counters(run))
      else
        mark_failed!(run, error: "unknown WebhookEngineClient response: #{response.inspect}")
      end

      run
    end

    def ingest_stats!(run:, source:, stats:, recorded_at:)
      payloads = Ingestion::Mappers::WebhookEngineMapper.map_stats(
        stats: stats, source: source, recorded_at: recorded_at
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
        Rails.logger.error("[webhook_engine_pull] ingest error: #{e.class}: #{e.message}")
      end

      run.update_columns(
        signals_attempted: attempted,
        signals_stored: stored,
        signals_rejected: rejected,
        signals_deduped: deduped,
        updated_at: Time.now.utc
      )
    end

    def run_counters(run)
      run.reload
      { attempted: run.signals_attempted, stored: run.signals_stored,
        rejected: run.signals_rejected, deduped: run.signals_deduped }
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
      Ecosystem::WebhookEngineClient.instance || Ecosystem::WebhookEngineClient.new
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
