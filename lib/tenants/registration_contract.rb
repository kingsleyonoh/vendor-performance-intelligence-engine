# frozen_string_literal: true

require "dry-validation"

module Tenants
  # dry-validation contract for POST /api/tenants/register (PRD §5.1 + §8b).
  # Enforces the §4.T identity-column shape before any DB write — missing
  # fields surface as `VALIDATION_ERROR` with `details: [{path, issue}]`
  # via `Api::BaseController#render_api_error`.
  class RegistrationContract < Dry::Validation::Contract
    HEX_COLOR = /\A#[0-9A-Fa-f]{6}\z/
    SLUG_FORMAT = /\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

    params do
      required(:slug).filled(:string)
      required(:legal_name).filled(:string)
      required(:full_legal_name).filled(:string)
      required(:display_name).filled(:string)
      required(:address).filled(:hash)
      required(:registration).filled(:hash)
      required(:contact).filled(:hash)
      optional(:locale).filled(:string)
      optional(:timezone).filled(:string)
      optional(:wordmark_url).maybe(:string)
      optional(:brand_primary_hex).filled(:string)
      optional(:brand_accent_hex).filled(:string)
    end

    rule(:slug) do
      key.failure("must be lowercase alphanumeric with dashes") unless value.to_s.match?(SLUG_FORMAT)
    end

    rule(:address) do
      cc = value.is_a?(Hash) ? (value[:country_code] || value["country_code"]) : nil
      key.failure("must include country_code") if cc.to_s.strip.empty?
    end

    rule(:registration) do
      h = value.is_a?(Hash) ? value : {}
      tax_id = h[:tax_id] || h["tax_id"]
      company_number = h[:company_number] || h["company_number"]
      if tax_id.to_s.strip.empty? && company_number.to_s.strip.empty?
        key.failure("must include tax_id or company_number")
      end
    end

    rule(:contact) do
      email = value.is_a?(Hash) ? (value[:email] || value["email"]) : nil
      key.failure("must include email") if email.to_s.strip.empty?
    end

    rule(:brand_primary_hex) do
      key.failure("must be a #RRGGBB hex color") if value && !value.to_s.match?(HEX_COLOR)
    end

    rule(:brand_accent_hex) do
      key.failure("must be a #RRGGBB hex color") if value && !value.to_s.match?(HEX_COLOR)
    end
  end
end
