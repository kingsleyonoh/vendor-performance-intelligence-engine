# frozen_string_literal: true

module Reports
  # ExpiredReportReaperJob — PRD §7, §13.3.
  #
  # Hourly cron. For every `vendor_reports` row with status='ready' and
  # expires_at <= Time.now.utc:
  #   1. Delete the storage_path file (idempotent: missing file is fine).
  #   2. Transition status: ready → expired.
  #   3. Audit the action.
  #
  # Honors REPORT_RETENTION_DAYS (§14) indirectly — the retention window
  # is applied by ReportGeneratorJob when setting expires_at.
  class ExpiredReportReaperJob < ApplicationJob
    queue_as :default

    def perform
      reaped = 0
      VendorReport
        .where(status: "ready")
        .where("expires_at IS NOT NULL AND expires_at <= ?", Time.now.utc)
        .find_each do |report|
          reap_one(report)
          reaped += 1
        end

      Rails.logger.tagged("reports.reaper") do
        Rails.logger.info("ExpiredReportReaperJob: reaped #{reaped} expired reports")
      end
      reaped
    end

    private

    def reap_one(report)
      delete_storage_file(report)
      report.transition_to!("expired")
      record_audit(report)
    rescue StandardError => e
      Rails.logger.error("ExpiredReportReaperJob: report=#{report.id} reap failed: #{e.class}: #{e.message}")
    end

    def delete_storage_file(report)
      path = report.storage_path
      return if path.blank?
      return unless File.exist?(path)

      File.delete(path)
    end

    def record_audit(report)
      ::Audit::Recorder.record(
        actor: "Reports::ExpiredReportReaperJob",
        action: "reports#expired",
        entity_type: "VendorReport",
        entity_id: report.id,
        tenant_id: report.tenant_id,
        after_state: { status: "expired" }
      )
    rescue StandardError => e
      Rails.logger.error("ExpiredReportReaperJob audit failed: #{e.class}: #{e.message}")
    end
  end
end
