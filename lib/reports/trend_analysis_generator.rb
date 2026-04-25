# frozen_string_literal: true

require "csv"
require "wicked_pdf"

module Reports
  # Weekly trend aggregates (PRD §5, §13.3). CSV (default) or PDF over
  # the configured window_days (default 90). Bound to FROZEN render_context.
  class TrendAnalysisGenerator < BaseGenerator
    PDF_TEMPLATE_PATH = Rails.root.join("app/views/reports/trend_analysis.pdf.erb").freeze
    HEADERS = %w[
      week_start total_vendors low medium high critical avg_composite_score
    ].freeze

    protected

    def render
      buckets = f("data.weekly_buckets")
      _       = f("tenant.legal_name")

      case @report.output_format
      when "csv"
        { bytes: render_csv(buckets), extension: "csv", inline: true }
      when "pdf"
        { bytes: render_pdf, extension: "pdf", inline: false }
      else
        raise ArgumentError, "Unsupported output_format: #{@report.output_format}"
      end
    end

    private

    def render_csv(buckets)
      CSV.generate do |csv|
        csv << HEADERS
        Array(buckets).each do |b|
          bc = b["band_counts"] || {}
          csv << [
            b["week_start"],
            b["score_count"],
            bc["low"] || 0,
            bc["medium"] || 0,
            bc["high"] || 0,
            bc["critical"] || 0,
            format("%.2f", b["avg_composite"].to_f)
          ]
        end
      end
    end

    def render_pdf
      template_source = File.read(PDF_TEMPLATE_PATH)
      view = VendorScorecardGenerator::TemplateContext.new(@context)
      html = ERB.new(template_source, trim_mode: "-").result(view.binding_for_template)
      WickedPdf.new.pdf_from_string(
        html,
        page_size: "A4",
        margin: { top: 12, bottom: 12, left: 12, right: 12 },
        encoding: "UTF-8"
      )
    end
  end
end
