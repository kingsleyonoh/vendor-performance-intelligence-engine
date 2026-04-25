# frozen_string_literal: true

module Alerts
  # Alerts::BandChangePillComponent — visual representation of a risk-band
  # crossing (previous → new). Reuses the same color palette as
  # `Vendors::BandPillComponent` so the operator's mental model is consistent
  # across screens.
  class BandChangePillComponent < ViewComponent::Base
    BAND_COLORS = ::Vendors::BandPillComponent::BAND_COLORS

    def initialize(previous_band:, new_band:)
      @previous_band = previous_band
      @new_band = new_band
    end

    attr_reader :previous_band, :new_band

    def previous_color
      BAND_COLORS[previous_band] || "#CBD5E0"
    end

    def new_color
      BAND_COLORS[new_band] || "#CBD5E0"
    end
  end
end
