# frozen_string_literal: true

# ScoringRule — PRD §4.7. Per-tenant declarative configuration for the
# composite scorer. Invariant 6 (rules-driven, not ML): every weight +
# threshold lives on this row; the scorer reads them verbatim.
#
# Exactly one rule per tenant may have `is_active = true`; enforced by the
# `scoring_rules_tenant_active_uidx` partial unique index. Activating a new
# rule atomically deactivates any currently-active one (same-transaction
# callback below).
class ScoringRule < ApplicationRecord
  CATEGORIES = %w[financial operational contractual integration transactional].freeze
  BAND_KEYS = %w[low_max medium_max high_max].freeze

  belongs_to :tenant

  validates :tenant, presence: true
  validates :name, presence: true, length: { maximum: 200 }
  validates :window_days, numericality: { greater_than: 0 }
  validates :time_decay_half_life_days, numericality: { greater_than: 0 }

  validate :validate_category_weights
  validate :validate_band_thresholds

  before_save :set_activated_at
  around_save :deactivate_sibling_if_activating

  private

  def validate_category_weights
    weights = category_weights.is_a?(Hash) ? category_weights.transform_keys(&:to_s) : {}

    missing = CATEGORIES - weights.keys
    if missing.any?
      errors.add(:category_weights, "must include all 5 categories (missing: #{missing.join(', ')})")
      return
    end

    sum = weights.slice(*CATEGORIES).values.map(&:to_f).sum
    unless (sum - 1.00).abs <= 0.01
      errors.add(:category_weights, "values must sum to 1.00 (± 0.01); got #{sum.round(3)}")
    end
  end

  def validate_band_thresholds
    thresholds = band_thresholds.is_a?(Hash) ? band_thresholds.transform_keys(&:to_s) : {}

    missing = BAND_KEYS - thresholds.keys
    if missing.any?
      errors.add(:band_thresholds, "must include keys (missing: #{missing.join(', ')})")
      return
    end

    low = thresholds["low_max"].to_f
    med = thresholds["medium_max"].to_f
    high = thresholds["high_max"].to_f

    unless low < med && med < high
      errors.add(:band_thresholds, "must be strictly ascending low_max < medium_max < high_max")
    end
  end

  # Stamp activated_at the instant is_active flips false → true.
  def set_activated_at
    if is_active? && is_active_changed?(from: false, to: true)
      self.activated_at ||= Time.now.utc
    end
  end

  # Deactivate any other active rule for this tenant atomically when we
  # activate a new one. Wrapping the save in a transaction ensures both
  # rows settle together; the partial unique index would otherwise bounce
  # the INSERT/UPDATE.
  def deactivate_sibling_if_activating
    if is_active? && (is_active_changed?(from: false, to: true) || new_record?)
      self.class.transaction do
        self.class.where(tenant_id: tenant_id, is_active: true)
                  .where.not(id: id || "00000000-0000-0000-0000-000000000000")
                  .update_all(is_active: false, updated_at: Time.now.utc)
        yield
      end
    else
      yield
    end
  end
end
