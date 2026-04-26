# frozen_string_literal: true

require "test_helper"
require "pdf-reader"
require "stringio"

# Reports::VendorScorecardGenerator — PRD §5, §13.3. Renders a PDF
# vendor scorecard from the FROZEN render_context stored on
# `vendor_reports.render_context` at the queued → generating transition.
# Generators NEVER re-query the database — they bind to the captured
# snapshot only.
#
# Verifies:
#   - PDF file is written to REPORT_STORAGE_PATH/{report_id}.pdf
#   - storage_path is updated on the vendor_report
#   - generator does NOT issue any DB queries during render
#   - re-render after source mutation produces byte-identical bytes
#   - missing render_context tokens raise StrictFetchError
#   - cross-tenant fixtures (acme + globex) — no leakage
module Reports
  class VendorScorecardGeneratorTest < ActiveSupport::TestCase
    setup do
      @tenant = tenants(:acme_gmbh_de)
      @vendor = vendors(:acme_alpha)
      @storage_dir = Rails.root.join("tmp/test_reports_#{SecureRandom.hex(4)}")
      FileUtils.mkdir_p(@storage_dir)
      ENV["REPORT_STORAGE_PATH"] = @storage_dir.to_s
    end

    teardown do
      FileUtils.rm_rf(@storage_dir) if @storage_dir && File.exist?(@storage_dir)
      ENV.delete("REPORT_STORAGE_PATH")
    end

    # ---------- Happy path ----------
    test "generates a valid PDF for a vendor_scorecard report" do
      report = build_ready_to_generate_report(report_type: "vendor_scorecard")

      Reports::VendorScorecardGenerator.call(vendor_report: report)

      report.reload
      assert report.storage_path.present?, "storage_path should be set after render"
      assert File.exist?(report.storage_path), "PDF file should exist on disk"
      assert report.storage_path.end_with?(".pdf")
      bytes = File.binread(report.storage_path)
      assert bytes.start_with?("%PDF-"), "file must be a real PDF (starts with %PDF-)"
      assert bytes.bytesize > 1_000, "PDF should be >1KB"
      assert bytes.bytesize < 5_000_000, "PDF should be <5MB"
    end

    test "generator does NOT issue any SELECT queries (frozen render_context only)" do
      report = build_ready_to_generate_report(report_type: "vendor_scorecard")
      report = VendorReport.find(report.id)

      select_queries = []
      counter = ->(_name, _start, _finish, _id, payload) {
        next if payload[:name] == "SCHEMA"

        sql = payload[:sql].to_s
        next if sql =~ /\A(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/

        # The generator may legitimately UPDATE the report row (storage_path)
        # and INSERT into audit_log_entries via the model's audit hook; what
        # it must NEVER do is SELECT vendor / score / signal data — that
        # would mean it bypassed the frozen render_context.
        select_queries << sql if sql =~ /\ASELECT/
      }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        Reports::VendorScorecardGenerator.call(vendor_report: report)
      end

      # Tables the generator MUST NOT query — every datum lives in render_context.
      forbidden = %w[vendors vendor_scores vendor_signals vendor_aliases tenants]
      leaked = select_queries.select { |q| forbidden.any? { |t| q.include?(" #{t} ") || q.include?(" #{t}.") } }
      assert leaked.empty?,
             "generator must not SELECT from #{forbidden.inspect}; saw: #{leaked.inspect}"
    end

    # ---------- PRD §15 #13 byte-identical re-render ----------
    test "re-render after source tenant mutation produces byte-identical PDF tenant section" do
      report = build_ready_to_generate_report(report_type: "vendor_scorecard")
      Reports::VendorScorecardGenerator.call(vendor_report: report)
      report.reload
      first_bytes = File.binread(report.storage_path)

      # Mutate source tenant — the generator must NOT see this change because
      # it reads from the frozen render_context only.
      @tenant.update!(legal_name: "RENAMED AFTER CAPTURE", display_name: "Renamed")
      @vendor.update!(canonical_name: "RENAMED VENDOR")

      # Re-render — must produce identical tenant block. wkhtmltopdf embeds a
      # creation timestamp + random ID, so the full bytes will differ. We
      # assert on the legacy markers: the original legal_name must still
      # appear in the second render's text-extracted content, and the
      # post-mutation legal_name must NOT appear.
      report.update!(storage_path: nil)
      Reports::VendorScorecardGenerator.call(vendor_report: report)
      report.reload
      second_bytes = File.binread(report.storage_path)

      first_text  = pdf_text(first_bytes)
      second_text = pdf_text(second_bytes)

      assert_includes first_text,  "Acme GmbH"
      assert_includes second_text, "Acme GmbH",
                      "second render must STILL show original legal_name (frozen render_context)"
      refute_includes second_text, "RENAMED AFTER CAPTURE",
                      "second render must NOT show post-mutation legal_name"
      refute_includes second_text, "RENAMED VENDOR",
                      "second render must NOT show post-mutation vendor name"
    end

    # ---------- Multi-tenant fixture coverage (PRD §15 #15) ----------
    test "rendering acme report does not leak globex identity literals" do
      acme_report = build_ready_to_generate_report(report_type: "vendor_scorecard")
      Reports::VendorScorecardGenerator.call(vendor_report: acme_report)
      acme_report.reload

      text = pdf_text(File.binread(acme_report.storage_path))

      globex = tenants(:globex_inc_us)
      refute_includes text, globex.legal_name
      refute_includes text, globex.full_legal_name
      refute_includes text, "1 Market Street"
      refute_includes text, globex.contact["email"]
    end

    test "rendering globex report does not leak acme identity literals" do
      globex_tenant = tenants(:globex_inc_us)
      globex_vendor = vendors(:globex_zeta)
      report = VendorReport.create!(
        tenant: globex_tenant,
        vendor: globex_vendor,
        report_type: "vendor_scorecard",
        output_format: "pdf",
        parameters: {},
        status: "queued"
      )
      report.update!(
        render_context: Reports::CaptureRenderContext.call(vendor_report: report)
      )
      report.transition_to!("generating")

      Reports::VendorScorecardGenerator.call(vendor_report: report)
      report.reload
      text = pdf_text(File.binread(report.storage_path))

      assert_includes text, "Globex"
      acme = tenants(:acme_gmbh_de)
      refute_includes text, acme.full_legal_name # "Acme Procurement GmbH"
      refute_includes text, "Hauptstraße"
    end

    # ---------- Strict-fetch failure (PRD §15 #14) ----------
    test "raises StrictFetchError when render_context is missing required tokens" do
      report = build_ready_to_generate_report(report_type: "vendor_scorecard")
      # Replace render_context with a malformed shape (missing tenant block)
      bad_ctx = { schema_version: "vpi.report.v1", data: {}, links: {}, report: {} }
      report.update_columns(render_context: bad_ctx)

      assert_raises(Reports::StrictFetchError) do
        Reports::VendorScorecardGenerator.call(vendor_report: report)
      end

      # PDF must NOT have been written if rendering failed
      report.reload
      if report.storage_path.present?
        refute File.exist?(report.storage_path), "no PDF should be written on render failure"
      end
    end

    private

    def build_ready_to_generate_report(report_type:, vendor: @vendor, parameters: {})
      report = VendorReport.create!(
        tenant: @tenant,
        vendor: vendor,
        report_type: report_type,
        output_format: report_type == "vendor_scorecard" ? "pdf" : "csv",
        parameters: parameters,
        status: "queued"
      )
      ctx = Reports::CaptureRenderContext.call(vendor_report: report)
      # Cast the deep-frozen Hash to JSON-round-trippable for jsonb storage,
      # then back to a frozen Hash on read (Rails handles the parse).
      report.update!(render_context: JSON.parse(ctx.to_json))
      report.transition_to!("generating")
      report
    end

    # Extract text from a wkhtmltopdf-generated PDF using pdf-reader.
    # wkhtmltopdf FlateDecode-compresses content streams, so a raw byte
    # grep cannot see the rendered text — we have to inflate via pdf-reader.
    def pdf_text(bytes)
      reader = PDF::Reader.new(StringIO.new(bytes))
      reader.pages.map(&:text).join("\n")
    end
  end
end
