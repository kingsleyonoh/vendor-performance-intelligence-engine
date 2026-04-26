# frozen_string_literal: true

require "alba"

# Alba serializer for `VendorScore` over the API (PRD §8b).
#
# Exposes every field needed by the Vendor Detail / Dashboard pages
# (PRD §5b): composite score, band, trend, category scores, top
# contributors (invariant 4), window days, and computed_at.
class VendorScoreSerializer
  include ::Alba::Resource

  attributes :id,
             :tenant_id,
             :vendor_id,
             :composite_score,
             :band,
             :trend,
             :category_scores,
             :top_contributors,
             :window_days,
             :signals_considered_count,
             :scoring_rules_id,
             :computed_at,
             :created_at
end
