# frozen_string_literal: true

require "test_helper"

# ExpiredReportReaperJob — PRD §7, §13.3.
#
# Hourly cron. For every `vendor_reports` row with status='ready' and
# expires_at < now: transition to 'expired', delete the storage_path file
# from disk, and audit the action. Future-dated rows are no-ops.
module Reports
  class ExpiredReportReaperJobTest < ActiveJob::TestCase
    setup do
      @tenant = tenants(:acme_gmbh_de)
      @vendor = vendors(:acme_alpha)
      @storage_dir = Rails.root.join("tmp/test_reaper_#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(@storage_dir)
    end

    teardown do
      FileUtils.rm_rf(@storage_dir) if @storage_dir && File.exist?(@storage_dir)
    end

    test "expired ready report → status=expired, file deleted" do
      file_path = @storage_dir.join("expired.pdf").to_s
      File.binwrite(file_path, "%PDF-1.4 stub")

      report = build_ready_report(storage_path: file_path, expires_at: 1.hour.ago)

      Reports::ExpiredReportReaperJob.perform_now

      report.reload
      assert_equal "expired", report.status
      refute File.exist?(file_path), "storage_path file should be deleted"
    end

    test "future expires_at is left untouched" do
      file_path = @storage_dir.join("alive.pdf").to_s
      File.binwrite(file_path, "%PDF-1.4 stub")

      report = build_ready_report(storage_path: file_path, expires_at: 1.hour.from_now)

      Reports::ExpiredReportReaperJob.perform_now

      report.reload
      assert_equal "ready", report.status
      assert File.exist?(file_path)
    end

    test "already-expired status is a no-op" do
      file_path = @storage_dir.join("gone.pdf").to_s
      report = build_ready_report(storage_path: file_path, expires_at: 1.hour.ago)
      report.update!(status: "expired")

      reaper_calls = []
      Reports::ExpiredReportReaperJob.new.tap do |job|
        job.singleton_class.send(:define_method, :reap_one) do |r|
          reaper_calls << r.id
          super(r) if defined?(super)
        end
      end

      Reports::ExpiredReportReaperJob.perform_now

      report.reload
      assert_equal "expired", report.status
    end

    test "missing file on disk is tolerated (idempotent reap)" do
      file_path = @storage_dir.join("never_existed.pdf").to_s
      report = build_ready_report(storage_path: file_path, expires_at: 1.hour.ago)

      assert_nothing_raised do
        Reports::ExpiredReportReaperJob.perform_now
      end

      report.reload
      assert_equal "expired", report.status
    end

    test "tenant-isolation: reaps both tenants' expired rows uniformly" do
      f1 = @storage_dir.join("acme.pdf").to_s
      f2 = @storage_dir.join("globex.pdf").to_s
      File.binwrite(f1, "stub")
      File.binwrite(f2, "stub")

      acme_report   = build_ready_report(storage_path: f1, expires_at: 1.hour.ago, tenant: tenants(:acme_gmbh_de))
      globex_report = build_ready_report(storage_path: f2, expires_at: 1.hour.ago, tenant: tenants(:globex_inc_us))

      Reports::ExpiredReportReaperJob.perform_now

      assert_equal "expired", acme_report.reload.status
      assert_equal "expired", globex_report.reload.status
    end

    test "logs count of reaped rows" do
      f1 = @storage_dir.join("a.pdf").to_s
      f2 = @storage_dir.join("b.pdf").to_s
      File.binwrite(f1, "stub")
      File.binwrite(f2, "stub")
      build_ready_report(storage_path: f1, expires_at: 1.hour.ago)
      build_ready_report(storage_path: f2, expires_at: 2.hours.ago)

      log_io = StringIO.new
      old_logger = Rails.logger
      Rails.logger = ActiveSupport::TaggedLogging.new(::Logger.new(log_io))
      begin
        Reports::ExpiredReportReaperJob.perform_now
      ensure
        Rails.logger = old_logger
      end

      log_io.rewind
      log_text = log_io.read
      assert_match(/reaped/i, log_text)
      assert_match(/2/, log_text)
    end

    private

    def build_ready_report(storage_path:, expires_at:, tenant: @tenant)
      report = VendorReport.create!(
        tenant: tenant,
        report_type: "portfolio_risk",
        output_format: "csv",
        parameters: {},
        status: "queued"
      )
      # Transition through legal states to ready.
      report.transition_to!("generating") do |r|
        r.render_context = { schema_version: "vpi.report.v1", tenant: { id: tenant.id } }
        r.tenant_snapshot = { id: tenant.id }
      end
      report.transition_to!("ready") do |r|
        r.storage_path = storage_path
        r.generated_at = expires_at - 7.days
        r.expires_at   = expires_at
      end
      report
    end
  end
end
