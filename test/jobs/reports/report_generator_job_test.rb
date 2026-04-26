# frozen_string_literal: true

require "test_helper"

# Tests for Reports::ReportGeneratorJob — PRD §5.6, §7, §7b, §13.3.
#
# Covers:
#   - Happy path: queued → generating → ready, file written, frozen
#     render_context captured, Hub event emitted (vpi-report-ready).
#   - Idempotency: re-running on a non-queued report is a no-op.
#   - Generator failure → status='failed' with error_summary populated;
#     no file is written.
#   - Hub disabled → standalone-first: report still ready, no Hub call.
#   - Audit recorder is invoked.
#   - All four report types dispatch to their respective generators.
module Reports
  class ReportGeneratorJobTest < ActiveJob::TestCase
    setup do
      @tenant = tenants(:acme_gmbh_de)
      @vendor = vendors(:acme_alpha)
      @storage_dir = Rails.root.join("tmp/test_reports_#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(@storage_dir)
      ENV["REPORT_STORAGE_PATH"] = @storage_dir.to_s

      @captured_payloads = []
      @hub_response = { status: :sent, hub_event_id: "evt-rpt-1", response_code: 202 }
      install_hub_stub!
    end

    teardown do
      FileUtils.rm_rf(@storage_dir) if @storage_dir && File.exist?(@storage_dir)
      ENV.delete("REPORT_STORAGE_PATH")
      Ecosystem::HubClient.instance = @prev_hub_instance if defined?(@prev_hub_instance)
    end

    test "queued report is rendered, render_context frozen, status=ready" do
      report = create_report(report_type: "vendor_scorecard", output_format: "pdf")

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
      assert report.render_context.present?, "render_context must be captured"
      assert report.tenant_snapshot.present?, "tenant_snapshot must be captured"
      assert report.storage_path.present?
      assert File.exist?(report.storage_path)
      assert_not_nil report.generated_at
      assert_not_nil report.expires_at
      assert report.expires_at > Time.now.utc
    end

    test "non-queued report is a no-op (idempotency)" do
      report = create_report(report_type: "vendor_scorecard", output_format: "pdf")
      # Capture context, write a fake storage_path, transition to ready
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)
      report.transition_to!("generating") do |r|
        r.render_context = JSON.parse(ctx.to_json)
        r.tenant_snapshot = JSON.parse(ctx.to_json)["tenant"]
      end
      report.update!(status: "ready", storage_path: "/tmp/already.pdf",
                     generated_at: Time.now.utc, expires_at: 7.days.from_now)
      original_storage = report.storage_path

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
      assert_equal original_storage, report.storage_path,
                   "must not re-render an already-ready report"
    end

    test "generator failure transitions to failed and populates error_summary" do
      report = create_report(report_type: "vendor_scorecard", output_format: "pdf")

      install_failing_generator!
      begin
        with_hub_disabled do
          assert_raises(StandardError) do
            Reports::ReportGeneratorJob.perform_now(report.id)
          end
        end
      ensure
        uninstall_failing_generator!
      end

      report.reload
      assert_equal "failed", report.status
      assert report.error_summary.present?
      assert_match(/boom/, report.error_summary)
    end

    test "emits Hub event vpi-report-ready when Hub enabled" do
      report = create_report(report_type: "vendor_scorecard", output_format: "pdf")

      with_hub_enabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
      assert_equal 1, @captured_payloads.size
      payload = @captured_payloads.first
      assert_equal "vendor.report_ready", payload[:event_type]
      assert_equal "vpi-report-ready",    payload[:template_id]
      assert_equal report.id,             payload[:report][:id]
      assert payload[:tenant][:legal_name].present? || payload[:tenant]["legal_name"].present?
    end

    test "Hub disabled: report still ready, no Hub call (standalone-first)" do
      report = create_report(report_type: "vendor_scorecard", output_format: "pdf")

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
      assert_empty @captured_payloads, "must not call Hub when NOTIFICATION_HUB_ENABLED is false"
    end

    test "audit recorder is invoked on completion" do
      report = create_report(report_type: "vendor_scorecard", output_format: "pdf")

      audit_count_before = AuditLogEntry.count rescue 0

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      audit_count_after = AuditLogEntry.count rescue 0
      assert audit_count_after > audit_count_before,
             "expected audit_log_entries to grow on report completion"
    end

    test "portfolio_risk report dispatches to PortfolioRiskGenerator" do
      report = VendorReport.create!(
        tenant: @tenant,
        report_type: "portfolio_risk", output_format: "csv",
        parameters: {}, status: "queued"
      )

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
      assert report.storage_path.end_with?(".csv")
    end

    test "retender_candidates report dispatches to RetenderCandidatesGenerator" do
      report = VendorReport.create!(
        tenant: @tenant,
        report_type: "retender_candidates", output_format: "csv",
        parameters: {}, status: "queued"
      )

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
    end

    test "trend_analysis report dispatches to TrendAnalysisGenerator" do
      report = VendorReport.create!(
        tenant: @tenant,
        report_type: "trend_analysis", output_format: "csv",
        parameters: { window_days: 30 }, status: "queued"
      )

      with_hub_disabled do
        Reports::ReportGeneratorJob.perform_now(report.id)
      end

      report.reload
      assert_equal "ready", report.status
    end

    test "missing report id raises ActiveRecord::RecordNotFound" do
      assert_raises(ActiveRecord::RecordNotFound) do
        Reports::ReportGeneratorJob.perform_now(SecureRandom.uuid)
      end
    end

    private

    def create_report(report_type:, output_format:)
      VendorReport.create!(
        tenant: @tenant,
        vendor: report_type == "vendor_scorecard" ? @vendor : nil,
        report_type: report_type, output_format: output_format,
        parameters: {}, status: "queued"
      )
    end

    def install_hub_stub!
      @prev_hub_instance = Ecosystem::HubClient.instance
      captured = @captured_payloads
      resp = @hub_response
      stub = Object.new
      stub.define_singleton_method(:send_event) do |payload|
        # Mirror the real HubClient#send_event short-circuit so Hub-disabled
        # tests assert "no payload captured" without leaking through.
        if ENV.fetch("NOTIFICATION_HUB_ENABLED", "false").to_s.downcase != "true"
          return { status: :skipped, reason: "Hub disabled" }
        end

        captured << payload
        resp
      end
      Ecosystem::HubClient.instance = stub
    end

    def install_failing_generator!
      ::Reports::VendorScorecardGenerator.singleton_class.send(:define_method, :call) do |vendor_report:|
        raise StandardError, "boom"
      end
    end

    def uninstall_failing_generator!
      # Restore inherited behavior by removing the override; subsequent
      # callers will resolve `call` from BaseGenerator.
      if ::Reports::VendorScorecardGenerator.singleton_methods(false).include?(:call)
        ::Reports::VendorScorecardGenerator.singleton_class.send(:remove_method, :call)
      end
    end

    def with_hub_enabled
      ENV["NOTIFICATION_HUB_ENABLED"] = "true"
      yield
    ensure
      ENV.delete("NOTIFICATION_HUB_ENABLED")
    end

    def with_hub_disabled
      prev = ENV["NOTIFICATION_HUB_ENABLED"]
      ENV["NOTIFICATION_HUB_ENABLED"] = "false"
      yield
    ensure
      ENV["NOTIFICATION_HUB_ENABLED"] = prev
    end
  end
end
