# frozen_string_literal: true

require "wicked_pdf"

module Reports
  # PDF vendor scorecard (PRD §5, §13.3). Renders an ERB template against
  # the FROZEN `vendor_reports.render_context` and converts the resulting
  # HTML into a PDF via WickedPDF (wkhtmltopdf wrapper). The generator
  # never queries the database — every datum comes from the captured
  # snapshot.
  #
  # The ERB template lives at app/views/reports/vendor_scorecard.pdf.erb
  # and uses `f(@context, "tenant.legal_name")` style strict fetches via
  # Reports::StrictFetch. Any missing token raises StrictFetchError.
  class VendorScorecardGenerator < BaseGenerator
    TEMPLATE_PATH = Rails.root.join("app/views/reports/vendor_scorecard.pdf.erb").freeze

    protected

    def render
      html = render_html
      bytes = WickedPdf.new.pdf_from_string(
        html,
        page_size: "A4",
        margin: { top: 12, bottom: 12, left: 12, right: 12 },
        encoding: "UTF-8",
        disable_smart_shrinking: true,
        print_media_type: true
      )
      { bytes: bytes, extension: "pdf", inline: false }
    end

    private

    def render_html
      template_source = File.read(TEMPLATE_PATH)
      view = TemplateContext.new(@context)
      ERB.new(template_source, trim_mode: "-").result(view.binding_for_template)
    end

    # Lightweight ERB binding context. Carries the render_context Hash and
    # exposes `f(...)` as the strict-fetch helper. We avoid pulling in
    # ActionView so the generator stays free of controller plumbing.
    class TemplateContext
      def initialize(context)
        @context = context
      end

      def f(path, default: ::Reports::StrictFetch::SENTINEL)
        ::Reports::StrictFetch.fetch_path(@context, path, default: default)
      end

      def h(text)
        ERB::Util.html_escape(text.to_s)
      end

      def format_score(value)
        format("%.1f", value.to_f)
      end

      def format_money_cents(cents, currency)
        return "—" if cents.nil?

        amount = (cents.to_i / 100.0).round(2)
        "#{currency} #{format('%.2f', amount)}"
      end

      def format_iso_date(iso_string)
        return "—" if iso_string.nil? || iso_string.to_s.empty?

        Time.parse(iso_string).strftime("%Y-%m-%d")
      rescue ArgumentError
        iso_string.to_s
      end

      def context
        @context
      end

      def binding_for_template
        binding
      end
    end
  end
end
