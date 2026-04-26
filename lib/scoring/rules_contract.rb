# frozen_string_literal: true

require "dry/validation"

module Scoring
  # dry-validation contract for scoring_rules CRUD — PRD §4.6, §8b.
  #
  # Enforces request-shape invariants BEFORE the ActiveRecord layer sees
  # the payload. The AR model re-validates (defense in depth + returning a
  # different error envelope), so nothing here leaks through to a bad row.
  #
  # Contract (all keys required for CREATE):
  #   name                       — non-blank string
  #   category_weights           — hash with the 5 canonical keys, summing to ≈ 1.00
  #   band_thresholds            — { low_max, medium_max, high_max } strictly ascending, in [0,100]
  #   window_days                — integer > 0
  #   time_decay_half_life_days  — integer > 0
  #   signal_weight_overrides    — optional hash of {signal_code => weight in [0,1]}
  class RulesContract < Dry::Validation::Contract
    CATEGORIES = %w[financial operational contractual integration transactional].freeze
    BAND_KEYS = %w[low_max medium_max high_max].freeze

    params do
      required(:name).filled(:string)
      required(:category_weights).hash
      required(:band_thresholds).hash
      required(:window_days).filled(:integer)
      required(:time_decay_half_life_days).filled(:integer)
      optional(:signal_weight_overrides).maybe(:hash)
    end

    rule(:category_weights) do
      weights = value || {}
      norm = weights.transform_keys(&:to_s)
      missing = CATEGORIES - norm.keys
      if missing.any?
        key.failure("must include all 5 categories (missing: #{missing.join(', ')})")
      else
        nums = norm.slice(*CATEGORIES).values
        if nums.any? { |n| !n.is_a?(Numeric) }
          key.failure("each category weight must be numeric")
        else
          sum = nums.map(&:to_f).sum
          key.failure("values must sum to 1.00 (± 0.01); got #{sum.round(3)}") unless (sum - 1.0).abs <= 0.01
          key.failure("each category weight must be in [0, 1]") if nums.any? { |n| n.to_f < 0 || n.to_f > 1 }
        end
      end
    end

    rule(:band_thresholds) do
      thresholds = (value || {}).transform_keys(&:to_s)
      missing = BAND_KEYS - thresholds.keys
      if missing.any?
        key.failure("must include keys (missing: #{missing.join(', ')})")
      else
        low = thresholds["low_max"].to_f
        med = thresholds["medium_max"].to_f
        high = thresholds["high_max"].to_f
        if [low, med, high].any? { |v| v < 0.0 || v > 100.0 }
          key.failure("every threshold must be in [0, 100]")
        elsif !(low < med && med < high)
          key.failure("must be strictly ascending low_max < medium_max < high_max")
        end
      end
    end

    rule(:window_days) do
      key.failure("must be > 0") if value.to_i <= 0
    end

    rule(:time_decay_half_life_days) do
      key.failure("must be > 0") if value.to_i <= 0
    end

    rule(:signal_weight_overrides) do
      next if value.nil? || value.empty?

      overrides = value.transform_keys(&:to_s)
      bad_weights = overrides.select { |_, w| !(w.is_a?(Numeric) && w.to_f >= 0 && w.to_f <= 1) }
      key.failure("every override value must be a number in [0, 1]") if bad_weights.any?
    end

    # Render the Dry::Validation result's errors as the PRD §8b
    # `details: [{path, issue}]` shape.
    def self.details_for(result)
      result.errors.to_h.flat_map do |path, messages|
        Array(messages).map { |m| { path: path.to_s, issue: m } }
      end
    end
  end
end
