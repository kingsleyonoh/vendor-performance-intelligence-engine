# frozen_string_literal: true

module Settings
  # Settings → Scoring Rules UI controller — PRD §5b, §8, §13.3.
  #
  # HTML/Turbo surface for tuning the active scoring_rule. Mirror of
  # `Api::ScoringRulesController` (JSON). Both scope on `Current.tenant.id`.
  #
  # PRD §5b "Tune scoring weights" journey:
  #   - GET /settings/scoring → show active rule + edit form
  #   - POST /settings/scoring → create a NEW rule (is_active=true) and
  #     atomically deactivate the previously-active rule (delegated to
  #     ScoringRule#deactivate_sibling_if_activating around-save callback).
  #
  # Preview is delegated to `Scoring::RulePreviewer` and surfaced via the
  # JSON API (the preview button POSTs to /api/scoring_rules/:id/preview).
  class ScoringController < ApplicationController
    def show
      @active_rule = active_rule
      @form_rule   = @active_rule || ScoringRule.new(default_attrs)
    end

    def create
      attrs = parse_params

      new_rule = ScoringRule.new(
        attrs.merge(tenant: Current.tenant, is_active: true)
      )

      if new_rule.save
        Audit::Recorder.record(
          actor: Current.user || "tenant:#{Current.tenant.slug}",
          action: "scoring_rule.activated",
          entity_type: "ScoringRule",
          entity_id: new_rule.id,
          tenant_id: Current.tenant.id,
          after_state: { name: new_rule.name }
        )
        redirect_to settings_scoring_path, notice: "Scoring rule '#{new_rule.name}' saved and activated."
      else
        @active_rule = active_rule
        @form_rule   = new_rule
        flash.now[:alert] = new_rule.errors.full_messages.join("; ")
        render :show, status: :unprocessable_entity
      end
    end

    private

    def active_rule
      ScoringRule.where(tenant_id: Current.tenant.id, is_active: true).first
    end

    def default_attrs
      {
        name: "New rule",
        category_weights: {
          "financial" => 0.35, "operational" => 0.15, "contractual" => 0.30,
          "integration" => 0.15, "transactional" => 0.05
        },
        signal_weight_overrides: {},
        band_thresholds: { "low_max" => 25.0, "medium_max" => 50.0, "high_max" => 75.0 },
        window_days: 90,
        time_decay_half_life_days: 45
      }
    end

    def parse_params
      raw = params.require(:scoring_rule).permit(
        :name, :window_days, :time_decay_half_life_days,
        category_weights: %i[financial operational contractual integration transactional],
        band_thresholds:  %i[low_max medium_max high_max]
      ).to_h.symbolize_keys

      raw[:window_days]                = raw[:window_days].to_i if raw[:window_days].present?
      raw[:time_decay_half_life_days]  = raw[:time_decay_half_life_days].to_i if raw[:time_decay_half_life_days].present?
      raw[:category_weights]           = (raw[:category_weights] || {}).transform_keys(&:to_s).transform_values { |v| v.to_f }
      raw[:band_thresholds]            = (raw[:band_thresholds]  || {}).transform_keys(&:to_s).transform_values { |v| v.to_f }
      raw[:signal_weight_overrides]    = {}
      raw
    end
  end
end
