# frozen_string_literal: true

# Vendors::VendorRowComponent — a single row in the vendors list table.
# Displays band + composite score from the pre-fetched latest-scores hash
# to keep the page free of N+1 score lookups.
module Vendors
  class VendorRowComponent < ViewComponent::Base
    def initialize(vendor:, score: nil)
      @vendor = vendor
      @score = score
    end

    attr_reader :vendor, :score

    def band
      score&.dig(:band)
    end

    def composite_score
      score&.dig(:composite_score)
    end

    def formatted_spend
      return "—" unless vendor.annual_spend_cents
      currency = vendor.currency || "EUR"
      amount = (vendor.annual_spend_cents / 100.0).round(0)
      "#{currency} #{amount.to_s.reverse.scan(/\d{1,3}/).join(",").reverse}"
    end

    def last_score_at
      score&.dig(:computed_at)&.to_time&.strftime("%Y-%m-%d") || "—"
    end
  end
end
