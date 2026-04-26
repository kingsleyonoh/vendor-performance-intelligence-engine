# frozen_string_literal: true

# Vendors::HeaderComponent — top-of-page summary for the vendor detail
# screen (PRD §5b step 3). Renders canonical_name, band pill, composite
# score, trend arrow, spend, category, status, and the action buttons.
module Vendors
  class HeaderComponent < ViewComponent::Base
    TREND_GLYPHS = {
      "improving" => "↓",
      "stable"    => "→",
      "degrading" => "↑",
      "new"       => "•"
    }.freeze

    def initialize(vendor:, score: nil)
      @vendor = vendor
      @score = score
    end

    attr_reader :vendor, :score

    def band
      score&.band
    end

    def composite_score
      score&.composite_score&.to_f
    end

    def trend
      score&.trend
    end

    def trend_glyph
      TREND_GLYPHS[trend] || "—"
    end

    def formatted_spend
      return "—" unless vendor.annual_spend_cents
      currency = vendor.currency || "EUR"
      amount = (vendor.annual_spend_cents / 100.0).round(0)
      "#{currency} #{amount.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}"
    end
  end
end
