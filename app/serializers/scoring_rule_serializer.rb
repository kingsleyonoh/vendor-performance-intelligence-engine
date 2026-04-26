# frozen_string_literal: true

require "alba"

# Alba serializer for `ScoringRule` — PRD §4.6, §8b.
#
# Exposes every knob the operator tunes in the UI (category weights, band
# thresholds, signal overrides, window + decay) plus the activation
# lifecycle timestamps. Tenant_id intentionally excluded (the caller is
# already scoped to their tenant via Current.tenant).
class ScoringRuleSerializer
  include ::Alba::Resource

  attributes :id,
             :name,
             :is_active,
             :category_weights,
             :signal_weight_overrides,
             :band_thresholds,
             :window_days,
             :time_decay_half_life_days,
             :activated_at,
             :created_at,
             :updated_at
end
