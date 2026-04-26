# frozen_string_literal: true

require "dry/validation"

module Ingestion
  # dry-validation contract for /api/ingestion/sources CRUD — PRD §5, §8b.
  #
  # Enforces request-shape invariants before AR validations. The most
  # important rule is the secret-reference guard: `connection_config`
  # MUST express secrets as `ENV:VAR_NAME` references — never inline raw
  # API keys / passwords. This catches the "operator pastes a real key
  # into a request body" failure mode before the row is persisted.
  class SourceContract < Dry::Validation::Contract
    SOURCE_SYSTEMS = IngestionSource::SOURCE_SYSTEMS
    PULL_MODES     = IngestionSource::PULL_MODES

    # Recognized secret-bearing keys inside connection_config. Any value
    # for one of these keys must look like an `ENV:` reference.
    SECRET_REF_KEYS = %w[api_key_ref api_secret_ref token_ref password_ref].freeze

    # Disallowed raw-secret keys — if present, the operator inlined a
    # secret. Reject the request rather than persist it.
    RAW_SECRET_KEYS = %w[api_key api_secret token password client_secret bearer].freeze

    ENV_REF_REGEX = /\AENV:[A-Z][A-Z0-9_]*\z/

    params do
      required(:source_system).filled(:string)
      optional(:is_enabled).maybe(:bool)
      optional(:connection_config).maybe(:hash)
      optional(:pull_mode).filled(:string)
      optional(:pull_interval_minutes).filled(:integer)
    end

    rule(:source_system) do
      unless SOURCE_SYSTEMS.include?(value.to_s)
        key.failure("must be one of #{SOURCE_SYSTEMS.inspect}")
      end
    end

    rule(:pull_mode) do
      next if value.nil?
      unless PULL_MODES.include?(value.to_s)
        key.failure("must be one of #{PULL_MODES.inspect}")
      end
    end

    rule(:pull_interval_minutes) do
      next if value.nil?
      key.failure("must be > 0") if value.to_i <= 0
    end

    rule(:connection_config) do
      cfg = (value || {}).transform_keys(&:to_s)

      RAW_SECRET_KEYS.each do |raw_key|
        if cfg.key?(raw_key)
          key.failure(
            "raw secret detected (#{raw_key}); use api_key_ref: \"ENV:VAR_NAME\" instead — " \
              "secrets must never be persisted in connection_config"
          )
        end
      end

      SECRET_REF_KEYS.each do |ref_key|
        next unless cfg.key?(ref_key)
        v = cfg[ref_key].to_s
        unless v.match?(ENV_REF_REGEX)
          key.failure(
            "#{ref_key} must be an ENV reference matching ENV:VAR_NAME (got #{v.inspect})"
          )
        end
      end
    end

    def self.details_for(result)
      result.errors.to_h.flat_map do |path, messages|
        Array(messages).map { |m| { path: path.to_s, issue: m } }
      end
    end
  end
end
