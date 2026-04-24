# frozen_string_literal: true

module Scoring
  # Scoring::CompositeScorer — PRD §5.4. Given a vendor_id (scoped to the
  # caller's tenant), compose all in-window signals + the active scoring_rule
  # into a single deterministic `vendor_scores` row.
  #
  # Invariant 3: scores are derived from signals — never patched. A fresh
  # row is inserted every call; history is preserved.
  # Invariant 4: every score row decomposes into `top_contributors` (at
  # most 5 entries, stable shape).
  # Invariant 5: the rolling window is `scoring_rule.window_days`.
  # Invariant 6: weights live on the scoring_rule row; no ML.
  #
  # Pipeline (per PRD §5.4):
  #   1. Load active scoring_rule for tenant (or use the provided one, for
  #      the preview endpoint).
  #   2. Query `vendor_signals` in window, status IN (normalized, scored),
  #      limited by SCORER_MAX_SIGNALS_PER_COMPUTE (safety cap).
  #   3. If no signals → return nil (do NOT insert an empty score).
  #   4. For each signal: resolve `SignalDefinition` → scale value via
  #      `SignalScalers` → apply time decay via `TimeDecay` → multiply by
  #      signal weight (override ?? default).
  #   5. Aggregate per category as a weighted average of contributions.
  #   6. Apply category weights → composite_score (clamped to [0, 100],
  #      rounded to 3 decimals for determinism).
  #   7. Classify band via `BandClassifier`.
  #   8. Compute trend against previous score (±5 threshold per PRD §5.4).
  #   9. Pick top 5 contributors by |contribution|.
  #  10. Insert vendor_scores row (atomic), return it.
  #
  # Band-crossing detection is exposed via `detect_band_crossing` — the
  # alert router (Phase 2) wires this into the band-change hook. The
  # scorer itself never fires alerts or enqueues jobs.
  class CompositeScorer
    TREND_DELTA = 5.0
    SCORE_PRECISION = 3
    DEFAULT_MAX_SIGNALS = 10_000

    # Public API.
    #
    # @param vendor_id [String] UUID
    # @param tenant [Tenant]
    # @param scoring_rule [ScoringRule, nil] overrides the active rule
    #        (for scoring-rule preview); nil → load active rule from DB
    # @param persist [Boolean] when false, returns a Hash without inserting
    #        a `vendor_scores` row. Used by the scoring-rule preview endpoint
    #        to simulate band changes without polluting history.
    # @return [VendorScore, Hash, nil] nil iff no signals in window; Hash when
    #         persist: false; VendorScore otherwise.
    def self.call(vendor_id:, tenant:, scoring_rule: nil, persist: true)
      new(vendor_id: vendor_id, tenant: tenant, scoring_rule: scoring_rule, persist: persist).call
    end

    # Band-crossing detector. Returns a frozen hash or nil.
    #
    # @param previous_band [String, Symbol, nil]
    # @param new_band [String, Symbol]
    # @return [Hash, nil] {from:, to:, direction: :worsening | :improving}
    def self.detect_band_crossing(previous_band:, new_band:)
      return nil if previous_band.nil? || previous_band.to_s.empty?

      prev = previous_band.to_s
      curr = new_band.to_s
      return nil if prev == curr

      prev_idx = VendorScore::BANDS.index(prev)
      curr_idx = VendorScore::BANDS.index(curr)
      return nil if prev_idx.nil? || curr_idx.nil?

      { from: prev, to: curr, direction: curr_idx > prev_idx ? :worsening : :improving }
    end

    def initialize(vendor_id:, tenant:, scoring_rule: nil, persist: true)
      raise ArgumentError, "vendor_id is required" if vendor_id.nil?
      raise ArgumentError, "tenant is required" if tenant.nil?

      @vendor_id = vendor_id
      @tenant = tenant
      @scoring_rule = scoring_rule
      @persist = persist
    end

    def call
      rule = resolve_rule!
      signals = load_signals(rule.window_days)
      return nil if signals.empty?

      contributions = signals.filter_map { |s| contribution_for(s, rule) }
      return nil if contributions.empty?

      category_scores = aggregate_categories(contributions)
      composite_score = composite_from_categories(category_scores, rule.category_weights)
      band = Scoring::BandClassifier.classify(
        composite_score: composite_score,
        band_thresholds: rule.band_thresholds
      ).to_s
      trend = compute_trend(composite_score)
      top = pick_top_contributors(contributions)

      attrs = {
        tenant_id: @tenant.id,
        vendor_id: @vendor_id,
        scoring_rule: rule,
        composite_score: composite_score,
        band: band,
        trend: trend,
        category_scores: category_scores_with_all_keys(category_scores),
        top_contributors: top,
        window_days: rule.window_days,
        signals_considered_count: signals.length,
        computed_at: Time.now.utc
      }

      return attrs.merge(scoring_rules_id: rule.id).except(:scoring_rule) unless @persist

      VendorScore.create!(attrs)
    end

    # ------------------------------------------------------------------

    private

    def resolve_rule!
      return @scoring_rule if @scoring_rule

      ScoringRule.where(tenant_id: @tenant.id, is_active: true).first!
    end

    def load_signals(window_days)
      cutoff = Time.now.utc - window_days.to_i.days
      VendorSignal
        .where(tenant_id: @tenant.id, vendor_id: @vendor_id)
        .where(status: %w[normalized scored])
        .where("recorded_at >= ?", cutoff)
        .order(recorded_at: :desc)
        .limit(max_signals_cap)
        .to_a
    end

    def max_signals_cap
      ENV.fetch("SCORER_MAX_SIGNALS_PER_COMPUTE", DEFAULT_MAX_SIGNALS.to_s).to_i
    end

    # Build a per-signal contribution record; nil if the signal cannot be
    # scored (unknown code, XOR-missing value). Defensive — ingestion
    # should have pre-rejected these, but we never crash the whole vendor
    # score because one signal is malformed.
    def contribution_for(signal, rule)
      definition = signal_definitions_cache[signal.signal_code]
      return nil unless definition

      raw_value = signal.value_numeric.nil? ? signal.value_boolean : signal.value_numeric.to_f
      return nil if raw_value.nil? && definition.value_type != "boolean"

      scaled = Scoring::SignalScalers.scale(
        value: raw_value,
        value_type: definition.value_type,
        direction: definition.direction,
        min_value: signal_bounds_for(definition, :min),
        max_value: signal_bounds_for(definition, :max)
      )

      age_days = (Time.now.utc - signal.recorded_at.to_time) / 1.day
      decay_weight = Scoring::TimeDecay.weight(
        age_days: age_days,
        half_life_days: rule.time_decay_half_life_days
      )

      signal_weight = signal_weight_for(definition, rule)
      contribution_value = scaled * decay_weight * signal_weight

      {
        signal_id: signal.id,
        signal_code: signal.signal_code,
        category: definition.category,
        scaled_value: scaled,
        decay_weight: decay_weight,
        signal_weight: signal_weight,
        contribution: contribution_value,
        raw_value: signal.value_numeric.nil? ? signal.value_boolean : signal.value_numeric.to_f
      }
    end

    # Aggregate contributions to a per-category weighted average in 0..100.
    # Sum(contribution) / Sum(decay * signal_weight) gives the mean scaled
    # risk within the category, weighted by each signal's decay × weight.
    def aggregate_categories(contributions)
      scores = {}
      contributions.group_by { |c| c[:category] }.each do |cat, rows|
        denom = rows.sum { |r| r[:decay_weight] * r[:signal_weight] }
        next if denom.zero?

        numer = rows.sum { |r| r[:scaled_value] * r[:decay_weight] * r[:signal_weight] }
        scores[cat] = clamp_0_100(numer / denom)
      end
      scores
    end

    def composite_from_categories(category_scores, category_weights)
      weights = category_weights.transform_keys(&:to_s)
      composite = VendorScore::CATEGORIES.sum do |cat|
        cat_score = category_scores[cat].to_f
        cat_weight = weights[cat].to_f
        cat_score * cat_weight
      end
      clamp_0_100(composite).round(SCORE_PRECISION)
    end

    def category_scores_with_all_keys(category_scores)
      VendorScore::CATEGORIES.each_with_object({}) do |cat, h|
        h[cat] = (category_scores[cat] || 0.0).to_f.round(SCORE_PRECISION)
      end
    end

    # Trend: compare against the most-recent prior VendorScore for this
    # (tenant, vendor). No prior → :new. Otherwise ±TREND_DELTA gives
    # stable/improving/degrading per PRD §5.4 step 8.
    def compute_trend(new_composite)
      prev = VendorScore
               .where(tenant_id: @tenant.id, vendor_id: @vendor_id)
               .order(computed_at: :desc)
               .first
      return "new" unless prev

      delta = new_composite - prev.composite_score.to_f
      return "stable" if delta.abs < TREND_DELTA

      delta.positive? ? "degrading" : "improving"
    end

    def pick_top_contributors(contributions)
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

    def signal_definitions_cache
      @signal_definitions_cache ||= SignalDefinition.all.index_by(&:code)
    end

    # SignalDefinition rows in this project don't carry per-signal
    # min/max bounds (the catalog is code + category + value_type +
    # direction only). For range-based value_types we still need bounds;
    # pull sane defaults from the signal_code so SignalScalers can
    # normalize. This keeps the scorer deterministic without requiring
    # every ingestion caller to embed bounds.
    SIGNAL_BOUNDS = {
      "count" => { min: 0, max: 100 },
      "duration_seconds" => { min: 0, max: 90 * 86_400 },  # up to 90 days
      "money_cents" => { min: 0, max: 10_000_000_00 }       # up to 10M currency-units
    }.freeze

    def signal_bounds_for(definition, which)
      return nil unless SIGNAL_BOUNDS.key?(definition.value_type)

      SIGNAL_BOUNDS.dig(definition.value_type, which)
    end

    def signal_weight_for(definition, rule)
      overrides = (rule.signal_weight_overrides || {}).transform_keys(&:to_s)
      if overrides.key?(definition.code)
        overrides[definition.code].to_f
      else
        definition.default_weight.to_f
      end
    end

    def clamp_0_100(value)
      v = value.to_f
      return 0.0 if v < 0.0
      return 100.0 if v > 100.0

      v
    end
  end
end
