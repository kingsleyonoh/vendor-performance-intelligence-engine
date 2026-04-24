# frozen_string_literal: true

# Scoring::TimeDecay — PRD §5.4. Pure exponential half-life decay used by
# the composite scorer to weight older signals less.
#
#   weight(age_days, half_life_days) = 0.5 ** (age_days / half_life_days)
#
# Defaults live in env (`DEFAULT_TIME_DECAY_HALF_LIFE_DAYS=45`, PRD §14)
# but this module knows nothing about env — the caller (composite_scorer)
# reads the active `scoring_rules.time_decay_half_life_days` off the
# rule row and passes it in. Keeping the primitive pure makes it unit
# testable and side-effect-free.
module Scoring
  module TimeDecay
    module_function

    # Compute the time-decay weight.
    #
    # @param age_days [Numeric] non-negative; a signal recorded today has age 0
    # @param half_life_days [Numeric] strictly positive
    # @return [Float] in (0.0, 1.0]; 1.0 for age 0, 0.5 for age == half_life
    def weight(age_days:, half_life_days:)
      unless half_life_days && half_life_days.to_f.positive?
        raise ArgumentError,
              "half_life_days must be positive (got #{half_life_days.inspect})"
      end

      age = [age_days.to_f, 0.0].max # clamp negative ages (future-dated signals)
      0.5**(age / half_life_days.to_f)
    end

    # Convenience — multiply an already-scaled contribution by the decay
    # weight. Used by the composite scorer when it aggregates per-category
    # contributions.
    #
    # @return [Float]
    def apply(value:, age_days:, half_life_days:)
      value.to_f * weight(age_days: age_days, half_life_days: half_life_days)
    end
  end
end
