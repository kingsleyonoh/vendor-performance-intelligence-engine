# frozen_string_literal: true

# Dashboard::KpiCardComponent — PRD §5b KPI grid. A single stat card
# (title + value + optional subtitle + optional band color accent).
module Dashboard
  class KpiCardComponent < ViewComponent::Base
    BAND_COLORS = {
      "low"      => "#48BB78",
      "medium"   => "#ECC94B",
      "high"     => "#ED8936",
      "critical" => "#E53E3E"
    }.freeze

    def initialize(title:, value:, subtitle: nil, band: nil, testid: nil)
      @title = title
      @value = value
      @subtitle = subtitle
      @band = band
      @testid = testid
    end

    attr_reader :title, :value, :subtitle, :band, :testid

    def accent_color
      BAND_COLORS[band] || "var(--brand-accent)"
    end
  end
end
