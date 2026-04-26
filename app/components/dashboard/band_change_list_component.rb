# frozen_string_literal: true

# Dashboard::BandChangeListComponent — PRD §5b. Renders up to 5 band-change
# events from the last 7 days. Links each row to the vendor detail page
# (Phase 1 item 4 — placeholder `#` until that lands).
module Dashboard
  class BandChangeListComponent < ViewComponent::Base
    def initialize(changes:)
      @changes = changes
    end

    attr_reader :changes

    def band_color(band)
      Dashboard::KpiCardComponent::BAND_COLORS[band] || "#718096"
    end
  end
end
