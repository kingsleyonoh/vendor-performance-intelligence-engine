# frozen_string_literal: true

# VendorScore — PRD §4.6. Composite score snapshots per vendor per tenant.
# Insert-only (scores are derived, never patched — invariant 3). The top_contributors
# column is load-bearing for invariant 4 (explainability): every score row
# MUST decompose into at most 5 contributing signals.
class VendorScore < ApplicationRecord
  self.table_name = "vendor_scores"

  BANDS = %w[low medium high critical].freeze
  TRENDS = %w[improving stable degrading new].freeze
  CATEGORIES = %w[financial operational contractual integration transactional].freeze
  MAX_CONTRIBUTORS = 5

  belongs_to :tenant
  belongs_to :vendor
  belongs_to :scoring_rule, foreign_key: :scoring_rules_id

  validates :composite_score,
            presence: true,
            numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 100.0 }
  validates :band, inclusion: { in: BANDS }
  validates :trend, inclusion: { in: TRENDS }
  validates :window_days, numericality: { greater_than: 0 }
  validates :signals_considered_count, numericality: { greater_than_or_equal_to: 0 }
  validates :scoring_rules_id, presence: true

  validate :validate_category_scores
  validate :validate_top_contributors

  scope :latest_for, ->(vendor) {
    where(vendor_id: vendor.is_a?(Vendor) ? vendor.id : vendor)
      .order(computed_at: :desc)
      .limit(1)
  }

  private

  def validate_category_scores
    keys = category_scores.is_a?(Hash) ? category_scores.transform_keys(&:to_s).keys : []
    missing = CATEGORIES - keys
    return if missing.empty?

    errors.add(:category_scores, "must include all 5 categories (missing: #{missing.join(', ')})")
  end

  def validate_top_contributors
    arr = top_contributors
    unless arr.is_a?(Array)
      errors.add(:top_contributors, "must be an array")
      return
    end

    if arr.length > MAX_CONTRIBUTORS
      errors.add(:top_contributors, "must have at most #{MAX_CONTRIBUTORS} entries (got #{arr.length})")
    end
  end
end
