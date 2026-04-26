# frozen_string_literal: true

# Scoring::SignalScalers — PRD §5.4. Pure-function registry that maps a raw
# signal value + its `value_type` + `direction` to a 0..100 risk contribution
# (100 = worst-case risk, 0 = ideal).
#
# This module is the single authority for turning heterogeneous raw values
# (rates, counts, durations, cents, booleans) into a uniform scale the
# composite scorer can aggregate. Kept deliberately pure (no DB, no Rails)
# so it can be unit-tested in isolation and reused from preview endpoints,
# ingestion validators, and rake tasks without side effects.
#
# Out-of-range inputs are CLAMPED (never raise) — the caller (ingestion
# validator) is responsible for logging "out of range" advisories upstream.
# Invalid configuration (missing bounds, unknown types) DOES raise
# ArgumentError: that's a programmer error, not a data anomaly.
module Scoring
  module SignalScalers
    VALUE_TYPES = %w[rate count duration_seconds money_cents boolean].freeze
    DIRECTIONS = %w[higher_is_worse lower_is_worse].freeze

    module_function

    # Scale a raw value to a 0..100 risk contribution.
    #
    # @param value [Numeric, Boolean] the raw signal value
    # @param value_type [String] one of VALUE_TYPES
    # @param direction [String] one of DIRECTIONS
    # @param min_value [Numeric, nil] required for count / duration_seconds / money_cents
    # @param max_value [Numeric, nil] required for count / duration_seconds / money_cents
    # @return [Float] 0.0..100.0
    def scale(value:, value_type:, direction:, min_value: nil, max_value: nil)
      validate_direction!(direction)

      case value_type
      when "rate"             then scale_rate(value, direction)
      when "boolean"          then scale_boolean(value, direction)
      when "count",
           "duration_seconds",
           "money_cents"      then scale_ranged(value, direction, min_value, max_value, value_type)
      else
        raise ArgumentError, "unknown value_type: #{value_type.inspect} (allowed: #{VALUE_TYPES.inspect})"
      end
    end

    # ------------------------------------------------------------------

    def validate_direction!(direction)
      return if DIRECTIONS.include?(direction)

      raise ArgumentError, "unknown direction: #{direction.inspect} (allowed: #{DIRECTIONS.inspect})"
    end

    def scale_rate(value, direction)
      v = clamp(value.to_f, 0.0, 1.0)
      direction == "higher_is_worse" ? v * 100.0 : (1.0 - v) * 100.0
    end

    def scale_boolean(value, direction)
      truthy = value == true
      if direction == "higher_is_worse"
        truthy ? 100.0 : 0.0
      else
        truthy ? 0.0 : 100.0
      end
    end

    def scale_ranged(value, direction, min_value, max_value, value_type)
      if min_value.nil? || max_value.nil?
        raise ArgumentError,
              "value_type=#{value_type} requires both min_value and max_value"
      end

      if max_value <= min_value
        raise ArgumentError,
              "value_type=#{value_type}: max_value (#{max_value}) must be > min_value (#{min_value})"
      end

      v = clamp(value.to_f, min_value.to_f, max_value.to_f)
      normalized = (v - min_value.to_f) / (max_value.to_f - min_value.to_f)

      direction == "higher_is_worse" ? normalized * 100.0 : (1.0 - normalized) * 100.0
    end

    def clamp(value, lower, upper)
      return lower if value < lower
      return upper if value > upper

      value
    end
  end
end
