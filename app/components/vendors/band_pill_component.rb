# frozen_string_literal: true

# Vendors::BandPillComponent — colored pill showing a vendor's current
# risk band. Colors follow PRD §5b chrome (matches
# `Dashboard::KpiCardComponent::BAND_COLORS`). Used in vendors list + vendor
# detail; Phase 3 alert emails reuse the same color map via CSS vars.
module Vendors
  class BandPillComponent < ViewComponent::Base
    BAND_COLORS = {
      "low"      => "#48BB78",
      "medium"   => "#ECC94B",
      "high"     => "#ED8936",
      "critical" => "#E53E3E"
    }.freeze

    def initialize(band:)
      @band = band
    end

    attr_reader :band

    def background
      BAND_COLORS[band] || "#CBD5E0"
    end
  end
end
