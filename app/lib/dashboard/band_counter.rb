# frozen_string_literal: true

# Dashboard::BandCounter — PRD §5b. Counts current-band occurrences per
# tenant by picking the latest `vendor_scores` row per (tenant, vendor)
# and bucketing its band. Returns a Hash with all 4 bands present (0 if
# none).
module Dashboard
  class BandCounter
    BANDS = %w[low medium high critical].freeze

    def self.call(tenant_id:)
      new(tenant_id: tenant_id).call
    end

    def initialize(tenant_id:)
      @tenant_id = tenant_id
    end

    def call
      rows = latest_per_vendor_bands
      counts = BANDS.index_with { 0 }
      rows.each { |b| counts[b] += 1 if counts.key?(b) }
      counts
    end

    private

    def latest_per_vendor_bands
      # SQL: for each (tenant_id, vendor_id) return the band of the most
      # recent row by computed_at.
      sql = <<~SQL
        SELECT DISTINCT ON (vendor_id) band
        FROM vendor_scores
        WHERE tenant_id = $1
        ORDER BY vendor_id, computed_at DESC
      SQL
      VendorScore.connection.exec_query(sql, "BandCounter", [@tenant_id]).rows.flatten
    end
  end
end
