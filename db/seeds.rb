# frozen_string_literal: true

# Seeds the system catalog of signal_definitions (PRD §4.4 + §13.1).
# Idempotent: re-running keeps row count unchanged. Row fields are UPSERTed
# by `code` so catalog tweaks (description edits, weight retuning) apply
# on the next boot / seed run.

require "yaml"

seed_path = Rails.root.join("db", "seeds", "signal_definitions.yml")
unless File.exist?(seed_path)
  warn "[seeds] Missing #{seed_path} — skipping signal_definitions seed"
  return
end

definitions = YAML.load_file(seed_path)
unless definitions.is_a?(Array)
  raise "[seeds] #{seed_path} must be a YAML list (got #{definitions.class})"
end

definitions.each do |attrs|
  attrs = attrs.transform_keys(&:to_sym)
  record = SignalDefinition.find_or_initialize_by(code: attrs[:code])
  record.assign_attributes(attrs)
  record.save!
end

puts "[seeds] signal_definitions: #{SignalDefinition.count} rows"

# ---------------------------------------------------------------------------
# Default scoring_rule per tenant — PRD §4.7 + §5.4. Upserts a "Default v1"
# rule for every persistent tenant so the composite scorer has an active
# rule to read on first boot. Operator clones + tunes; the clone activation
# atomically deactivates Default v1 via `ScoringRule#deactivate_sibling_if_activating`.
# ---------------------------------------------------------------------------
rules_seed_path = Rails.root.join("db", "seeds", "scoring_rules.yml")
if File.exist?(rules_seed_path)
  rule_template = YAML.load_file(rules_seed_path)
  unless rule_template.is_a?(Hash)
    raise "[seeds] #{rules_seed_path} must be a YAML hash (got #{rule_template.class})"
  end

  Tenant.find_each do |tenant|
    rule = ScoringRule.find_or_initialize_by(tenant_id: tenant.id, name: rule_template["name"])
    rule.assign_attributes(
      category_weights: rule_template["category_weights"],
      signal_weight_overrides: rule_template["signal_weight_overrides"] || {},
      band_thresholds: rule_template["band_thresholds"],
      window_days: rule_template["window_days"],
      time_decay_half_life_days: rule_template["time_decay_half_life_days"],
      is_active: rule_template["is_active"]
    )
    rule.save!
  end

  puts "[seeds] scoring_rules: #{ScoringRule.count} rows across #{Tenant.count} tenants"
end
