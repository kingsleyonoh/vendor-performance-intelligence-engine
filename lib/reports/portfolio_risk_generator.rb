# frozen_string_literal: true

require "csv"
require "wicked_pdf"

module Reports
  # Tenant-wide portfolio summary (PRD §5, §13.3). CSV (default) or PDF.
  # Bound to the FROZEN render_context — no live queries.
  class PortfolioRiskGenerator < BaseGenerator
    PDF_TEMPLATE_PATH = Rails.root.join("app/views/reports/portfolio_risk.pdf.erb").freeze
    HEADERS = %w[vendor_id canonical_name band composite_score].freeze

    protected

    def render
      # Force-resolve the required tokens up-front so missing-token bugs surface
      # via Reports::StrictFetchError before we fall through to the format
      # branches.
      vendors = f("data.vendors")
      _      = f("tenant.legal_name")

      case @report.output_format
      when "csv"
        { bytes: render_csv(vendors), extension: "csv", inline: true }
      when "pdf"
        { bytes: render_pdf, extension: "pdf", inline: false }
      else
        raise ArgumentError, "Unsupported output_format: #{@report.output_format}"
      end
    end

    private

    def render_csv(vendors)
      CSV.generate do |csv|
        csv << HEADERS
        Array(vendors).each do |v|
          csv << [v["vendor_id"], v["canonical_name"], v["band"], format("%.2f", v["composite_score"].to_f)]
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
