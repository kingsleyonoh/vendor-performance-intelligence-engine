# frozen_string_literal: true

# Vendors::ContributorTableComponent — top-5 signal contributors to the
# latest composite score. Reads the `top_contributors` JSONB column from
# the latest `vendor_scores` row (PRD §5.4). Required for PRD §2
# invariant 4: every score row explains itself.
module Vendors
  class ContributorTableComponent < ViewComponent::Base
    def initialize(score:)
      @score = score
    end

    attr_reader :score

    # Array of hashes: { "signal_code" => "...", "contribution" => Float, "value" => Numeric }
    def contributors
      return [] unless score
      Array(score.top_contributors)
    end

    def empty?
      contributors.empty?
    end
  end
end
