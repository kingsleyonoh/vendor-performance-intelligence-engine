# frozen_string_literal: true

# Scoring::BandClassifier — PRD §5.4 step 7. Pure-function classifier mapping
# a composite_score (0..100) + `band_thresholds` hash ({low_max, medium_max,
# high_max} per PRD §4.7) to a band symbol.
#
# Direction (PRD §4.7): higher composite_score = higher risk.
#   score <= low_max     → :low
#   score <= medium_max  → :medium
#   score <= high_max    → :high
#   score >  high_max    → :critical
#
# Score exactly at a threshold resolves to the LOWER band (`<=` semantics).
# Invalid inputs raise ArgumentError — the scorer has already produced a
# clamped composite_score, so a value outside [0, 100] or a non-ascending
# threshold triple is a programmer error, not a data anomaly.
#
# Kept deliberately pure (no DB, no Rails) so it can be unit-tested in
# isolation and reused from scoring-rule preview endpoints.
module Scoring
  module BandClassifier
    BAND_KEYS = %w[low_max medium_max high_max].freeze

    module_function

    # Classify a composite_score into a risk band.
    #
    # @param composite_score [Numeric] in [0.0, 100.0]
    # @param band_thresholds [Hash] ({low_max, medium_max, high_max});
    #        accepts both symbol and string keys (jsonb round-trip).
    # @return [Symbol] :low | :medium | :high | :critical
    def classify(composite_score:, band_thresholds:)
      validate_score!(composite_score)
      thresholds = validate_thresholds!(band_thresholds)

      score = composite_score.to_f

      if score <= thresholds["low_max"]
        :low
      elsif score <= thresholds["medium_max"]
        :medium
      elsif score <= thresholds["high_max"]
        :high
      else
        :critical
      end
    end

    # ------------------------------------------------------------------

    def validate_score!(score)
      raise ArgumentError, "composite_score is required" if score.nil?

      f = score.to_f
      unless f >= 0.0 && f <= 100.0
        raise ArgumentError,
              "composite_score must be in [0.0, 100.0], got #{score.inspect}"
      end
    end

    def validate_thresholds!(thresholds)
      raise ArgumentError, "band_thresholds is required" if thresholds.nil?

      unless thresholds.is_a?(Hash)
        raise ArgumentError,
              "band_thresholds must be a Hash, got #{thresholds.class}"
      end

      # Normalize keys (jsonb round-trip produces strings).
      normalized = thresholds.transform_keys(&:to_s)

      missing = BAND_KEYS - normalized.keys
      if missing.any?
        raise ArgumentError,
              "band_thresholds missing keys: #{missing.inspect}"
      end

      low  = normalized["low_max"].to_f
      med  = normalized["medium_max"].to_f
      high = normalized["high_max"].to_f

      unless low < med && med < high
        raise ArgumentError,
              "band_thresholds must be strictly ascending " \
              "(low_max=#{low} < medium_max=#{med} < high_max=#{high})"
      end

      unless low >= 0.0 && high <= 100.0
        raise ArgumentError,
              "band_thresholds must be within [0.0, 100.0] " \
              "(got low_max=#{low}, high_max=#{high})"
      end

      normalized
    end
  end
end
