# frozen_string_literal: true

module Reports
  # ReportGeneratorJob — PRD §5.6, §7, §7b, §13.3.
  #
  # Renders a `vendor_reports` row from `queued` to `ready`. The flow:
  #
  #   1. Load the report (raises if missing — Sidekiq retries are pointless).
  #   2. Skip if not in `queued` (idempotency).
  #   3. Transition queued → generating, capture frozen render_context +
  #      tenant_snapshot ONCE (PRD §5.6 — every re-render binds to these).
  #   4. Dispatch to the matching generator class (vendor_scorecard,
  #      portfolio_risk, retender_candidates, trend_analysis).
  #   5. Generator writes the file and updates storage_path / inline_payload.
  #   6. Transition generating → ready, set generated_at + expires_at, audit.
  #   7. Emit Hub event `vendor.report_ready` via HubClient (template_id
  #      `vpi-report-ready`). Hub disabled → log + skip (standalone-first).
  #   8. On any failure: transition to `failed`, populate error_summary,
  #      audit, re-raise so Sidekiq retries.
  #
  # SNAPSHOT-FREEZING INVARIANT (PRD §15 #13): once captured, render_context
  # and tenant_snapshot MUST NOT be mutated. Re-renders read the stored
  # snapshot only. The model's `validate_snapshot_immutability` enforces this.
  class ReportGeneratorJob < ApplicationJob
    queue_as :default

    GENERATORS = {
      "vendor_scorecard"     => ::Reports::VendorScorecardGenerator,
      "portfolio_risk"       => ::Reports::PortfolioRiskGenerator,
      "retender_candidates"  => ::Reports::RetenderCandidatesGenerator,
      "trend_analysis"       => ::Reports::TrendAnalysisGenerator
    }.freeze

    DEFAULT_RETENTION_DAYS = 7

    def perform(vendor_report_id)
      report = VendorReport.find(vendor_report_id)
      return nil unless report.status == "queued"

      capture_and_transition_to_generating!(report)
      dispatch_generator!(report)
      finalize_ready!(report)
      record_audit(report, action: "ready")
      emit_hub_event(report)

      report
    rescue StandardError => e
      mark_failed!(report, error: e) if defined?(report) && report
      raise
    end

    private

    def capture_and_transition_to_generating!(report)
      ctx = ::Reports::CaptureRenderContext.call(vendor_report: report)
      # JSON round-trip so jsonb storage matches what later re-renders read back.
      stored_ctx = JSON.parse(ctx.to_json)
      stored_tenant = stored_ctx["tenant"] || {}

      report.transition_to!("generating") do |r|
        r.render_context = stored_ctx
        r.tenant_snapshot = stored_tenant
      end
    end

    def dispatch_generator!(report)
      generator = GENERATORS.fetch(report.report_type) do
        raise ArgumentError, "Unknown report_type: #{report.report_type}"
      end
      generator.call(vendor_report: report)
    end

    def finalize_ready!(report)
      retention = ENV.fetch("REPORT_RETENTION_DAYS", DEFAULT_RETENTION_DAYS.to_s).to_i
      now = Time.now.utc
      report.transition_to!("ready") do |r|
        r.generated_at = now
        r.expires_at   = now + retention.days
      end
    end

    def mark_failed!(report, error:)
      summary = "#{error.class}: #{error.message}".byteslice(0, 1000)
      target_status = report.status == "generating" ? "failed" : nil
      target_status ||= "failed" if report.status == "queued"

      if target_status && %w[queued generating].include?(report.status)
        begin
          report.transition_to!("failed") do |r|
            r.error_summary = summary
          end
        rescue ::VendorReport::InvalidStatusTransition
          report.update_columns(status: "failed", error_summary: summary, updated_at: Time.now.utc)
        end
      end
      record_audit(report, action: "failed", error: summary)
    rescue StandardError => e
      Rails.logger.error("ReportGeneratorJob#mark_failed! audit failed: #{e.class}: #{e.message}")
    end

    def emit_hub_event(report)
      client = ::Ecosystem::HubClient.instance || ::Ecosystem::HubClient.new
      payload = build_hub_payload(report)
      response = client.send_event(payload)

      case response[:status]
      when :sent
        Rails.logger.tagged("reports.hub") do
          Rails.logger.info("ReportGeneratorJob: report=#{report.id} hub_event_id=#{response[:hub_event_id]}")
        end
      when :skipped
        Rails.logger.tagged("reports.hub") do
          Rails.logger.info("ReportGeneratorJob: report=#{report.id} hub_disabled — skipped emission")
        end
      when :failed
        Rails.logger.tagged("reports.hub") do
          Rails.logger.warn("ReportGeneratorJob: report=#{report.id} hub_send_failed code=#{response[:response_code]}")
        end
      end
    rescue ::Ecosystem::TransientFailure, ::Ecosystem::CircuitOpen => e
      # Report is ready locally — the Hub notification is best-effort. Log,
      # don't raise (we don't want to flip status back to failed).
      Rails.logger.warn("ReportGeneratorJob: hub emission transient failure #{e.class}: #{e.message}")
    end

    def build_hub_payload(report)
      tenant_snapshot = report.tenant_snapshot.is_a?(Hash) ? report.tenant_snapshot : {}
      links = (report.render_context.is_a?(Hash) ? report.render_context["links"] : nil) || {}

      {
        event_type: "vendor.report_ready",
        template_id: "vpi-report-ready",
        event_id: "vpi-report-#{report.id}",
        tenant: tenant_snapshot,
        report: {
          id: report.id,
          type: report.report_type,
          output_format: report.output_format,
          generated_at: report.generated_at&.utc&.iso8601,
          expires_at: report.expires_at&.utc&.iso8601,
          download_url: links["download_url"]
        },
        requested_by_user_id: report.requested_by_user_id,
        created_at: Time.now.utc.iso8601
      }
    end

    def record_audit(report, action:, **extra)
      ::Audit::Recorder.record(
        actor: "Reports::ReportGeneratorJob",
        action: "reports##{action}",
        entity_type: "VendorReport",
        entity_id: report.id,
        tenant_id: report.tenant_id,
        after_state: { status: report.status }.merge(extra.compact)
      )
    rescue StandardError => e
      Rails.logger.error("ReportGeneratorJob audit failed: #{e.class}: #{e.message}")
    end
  end
end
