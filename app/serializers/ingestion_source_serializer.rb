# frozen_string_literal: true

require "alba"

# Alba serializer for `IngestionSource` — PRD §8b.
#
# Sanitizes connection_config: every secret-reference key (api_key_ref,
# token_ref, etc.) is masked to `<configured>` in API responses so
# the response body itself never echoes ENV-var names back. Operators
# manage secret values via env config, not the API.
class IngestionSourceSerializer
  include ::Alba::Resource

  SECRET_KEYS = %w[api_key_ref api_secret_ref token_ref password_ref].freeze
  PLACEHOLDER = "<configured>"

  attributes :id,
             :source_system,
             :is_enabled,
             :pull_mode,
             :pull_interval_minutes,
             :last_successful_pull,
             :last_attempted_pull,
             :last_failure_reason,
             :created_at,
             :updated_at

  attribute :connection_config do |source|
    cfg = source.connection_config || {}
    cfg.each_with_object({}) do |(k, v), out|
      out[k] = SECRET_KEYS.include?(k.to_s) ? PLACEHOLDER : v
    end
  end
end
