# frozen_string_literal: true

require "dry/validation"

module Reports
  # dry-validation contract for POST /api/reports payloads. Validates the
  # request shape BEFORE the controller hits the database — the four
  # report types have different required parameters:
  #
  #   - vendor_scorecard requires parameters.vendor_id (UUID string).
  #   - portfolio_risk, retender_candidates, trend_analysis are
  #     tenant-wide and ignore parameters.vendor_id.
  #
  # Returns a Dry::Validation::Result. The controller then converts
  # `result.errors.to_h` into the JSON:API error envelope (`details`).
  class RequestContract < Dry::Validation::Contract
    REPORT_TYPES = %w[vendor_scorecard portfolio_risk retender_candidates trend_analysis].freeze
    OUTPUT_FORMATS = %w[pdf csv json].freeze

    UUID_REGEX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

    params do
      required(:report_type).filled(:string)
      required(:output_format).filled(:string)
      optional(:parameters).hash do
        optional(:vendor_id).filled(:string)
        optional(:vendor_ids).array(:string)
        optional(:window_start).filled(:string)
        optional(:window_end).filled(:string)
        optional(:window_days).filled(:integer)
      end
      optional(:requested_by_user_id).maybe(:integer)
    end

    rule(:report_type) do
      key.failure("must be one of #{REPORT_TYPES.join(', ')}") unless REPORT_TYPES.include?(value)
    end

    rule(:output_format) do
      key.failure("must be one of #{OUTPUT_FORMATS.join(', ')}") unless OUTPUT_FORMATS.include?(value)
    end

    # vendor_scorecard requires a vendor_id; the others must NOT carry one.
    rule(:report_type, parameters: :vendor_id) do
      next unless values[:report_type] == "vendor_scorecard"

      vid = values.dig(:parameters, :vendor_id)
      if vid.nil? || vid.to_s.strip.empty?
        key([:parameters, :vendor_id]).failure("vendor_scorecard requires parameters.vendor_id")
      elsif vid.to_s !~ UUID_REGEX
        key([:parameters, :vendor_id]).failure("must be a UUID")
      end
    end
  end
end
