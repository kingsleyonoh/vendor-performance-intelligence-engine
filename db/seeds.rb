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
