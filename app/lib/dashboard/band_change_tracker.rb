# frozen_string_literal: true

# Dashboard::BandChangeTracker — PRD §5b. Returns the top-5 largest
# band-change events in a rolling window (default last 7 days).
#
# Definition of "band change": the latest score row per vendor computed
# since `since`, compared against the prior score row (earliest-older).
# Sorted by absolute delta in composite_score descending.
#
# Returns an Array of Hashes:
#   { vendor_id:, vendor_name:, previous_band:, current_band:, delta: }
module Dashboard
  class BandChangeTracker
    LIMIT = 5

    def self.call(tenant_id:, since:)
      new(tenant_id: tenant_id, since: since).call
    end

    def initialize(tenant_id:, since:)
      @tenant_id = tenant_id
      @since = since
    end

    def call
      # Fetch all scores for this tenant in the window + ONE earlier score
      # per vendor as the "previous" anchor. Simplest tenant-scoped query
      # acceptable here; vendor_scores is indexed on (tenant_id, vendor_id,
      # computed_at DESC).
      scores = VendorScore
                 .where(tenant_id: @tenant_id)
                 .order(vendor_id: :asc, computed_at: :desc)
                 .to_a

      grouped = scores.group_by(&:vendor_id)

      changes = grouped.filter_map do |vendor_id, vendor_scores|
        latest = vendor_scores.first
        next unless latest.computed_at >= @since

        previous = vendor_scores[1]
        next unless previous

        next if latest.band == previous.band

        vendor = Vendor.where(tenant_id: @tenant_id, id: vendor_id).first
        next unless vendor

        {
          vendor_id: vendor_id,
          vendor_name: vendor.canonical_name,
          previous_band: previous.band,
          current_band: latest.band,
          delta: (latest.composite_score.to_f - previous.composite_score.to_f).round(2)
        }
      end

      changes.sort_by { |c| -c[:delta].abs }.first(LIMIT)
    end
  end
end
