# frozen_string_literal: true

module Scoring
  # Scoring::Aggregator — pure aggregation math extracted from
  # `Scoring::CompositeScorer`. Given a list of per-signal contribution
  # records, produces:
  #
  #   * category_scores  — weighted average per category, clamped 0..100,
  #                        rounded to SCORE_PRECISION, padded with all
  #                        VendorScore::CATEGORIES keys present.
  #   * composite_score  — weighted sum of categories using
  #                        rule.category_weights, clamped 0..100,
  #                        rounded to SCORE_PRECISION.
  #   * top_contributors — up to VendorScore::MAX_CONTRIBUTORS, sorted
  #                        by |contribution| desc, stable shape.
  #
  # Stateless / pure — no DB, no Time.now, no rule-loading. The composite
  # scorer feeds in already-decorated contribution rows; this module only
  # composes them. Every helper here was previously a private method on
  # CompositeScorer; behaviour is identical.
  class Aggregator
    SCORE_PRECISION = 3

    # @param contributions [Array<Hash>] each with keys :category, :scaled_value,
    #        :decay_weight, :signal_weight, :contribution, :signal_id, :signal_code,
    #        :raw_value
    # @param category_weights [Hash{String=>Numeric}] e.g. rule.category_weights
    # @return [Hash] { category_scores:, composite_score:, top_contributors: }
    def self.call(contributions:, category_weights:)
      cat_scores = aggregate_categories(contributions)
      composite = composite_from_categories(cat_scores, category_weights)
      top = pick_top_contributors(contributions)

      {
        category_scores: category_scores_with_all_keys(cat_scores),
        composite_score: composite,
        top_contributors: top
      }
    end

    # Aggregate contributions to a per-category weighted average in 0..100.
    # Sum(scaled * decay * weight) / Sum(decay * weight) gives the mean
    # scaled risk within the category.
    def self.aggregate_categories(contributions)
      scores = {}
      contributions.group_by { |c| c[:category] }.each do |cat, rows|
        denom = rows.sum { |r| r[:decay_weight] * r[:signal_weight] }
        next if denom.zero?

        numer = rows.sum { |r| r[:scaled_value] * r[:decay_weight] * r[:signal_weight] }
        scores[cat] = clamp_0_100(numer / denom)
      end
      scores
    end

    def self.composite_from_categories(category_scores, category_weights)
      weights = category_weights.transform_keys(&:to_s)
      composite = VendorScore::CATEGORIES.sum do |cat|
        cat_score = category_scores[cat].to_f
        cat_weight = weights[cat].to_f
        cat_score * cat_weight
      end
      clamp_0_100(composite).round(SCORE_PRECISION)
    end

    def self.category_scores_with_all_keys(category_scores)
      VendorScore::CATEGORIES.each_with_object({}) do |cat, h|
        h[cat] = (category_scores[cat] || 0.0).to_f.round(SCORE_PRECISION)
      end
    end

    def self.pick_top_contributors(contributions)
      contributions
        .sort_by { |c| -c[:contribution].abs }
        .first(VendorScore::MAX_CONTRIBUTORS)
        .map do |c|
          {
            "signal_id" => c[:signal_id],
            "signal_code" => c[:signal_code],
            "category" => c[:category],
            "contribution" => c[:contribution].round(SCORE_PRECISION),
            "raw_value" => c[:raw_value]
          }
        end
    end

    def self.clamp_0_100(value)
      v = value.to_f
      return 0.0 if v < 0.0
      return 100.0 if v > 100.0

      v
    end

    private_class_method :aggregate_categories, :composite_from_categories,
                         :category_scores_with_all_keys, :pick_top_contributors,
                         :clamp_0_100
  end
end
