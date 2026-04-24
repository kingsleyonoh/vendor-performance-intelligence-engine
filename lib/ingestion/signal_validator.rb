# frozen_string_literal: true

require "dry-validation"

module Ingestion
  # Ingestion::SignalValidator — PRD §5.3. dry-validation contract for
  # incoming signal payloads from every ingestion source (REST push, NATS,
  # Hub fanout, scheduled pull, manual). Runs BEFORE vendor resolution,
  # because an invalid payload must never create a vendor or an alias.
  #
  # Reject matrix (maps to `vendor_signals.rejection_reason`):
  #   - MISSING_VENDOR_REF
  #   - UNKNOWN_SIGNAL_CODE
  #   - VALUE_OUT_OF_RANGE
  #   - FUTURE_TIMESTAMP     (clock-skew tolerance: 1 hour)
  #   - STALE_TIMESTAMP      (older than MAX_SIGNAL_BACKFILL_DAYS, default 365)
  #   - WINDOW_INVERTED
  #
  # Called via `Ingestion::SignalValidator.call(payload_hash)` → returns a
  # Dry::Validation::Result. The canonical rejection_reason can be extracted
  # with `Ingestion::SignalValidator.rejection_reason_for(result)` for the
  # ingester's `rejection_reason` column.
  class SignalValidator < Dry::Validation::Contract
    FUTURE_TOLERANCE_SECONDS = 1 * 60 * 60 # 1 hour of clock skew
    VALID_SOURCE_SYSTEMS = %w[
      invoice_recon webhook_engine contract_engine
      recon_engine rag_platform manual
    ].freeze

    # Canonical reason sentinels (match vendor_signals.rejection_reason).
    REASONS = %w[
      MISSING_VENDOR_REF UNKNOWN_SIGNAL_CODE VALUE_OUT_OF_RANGE
      FUTURE_TIMESTAMP STALE_TIMESTAMP WINDOW_INVERTED
    ].freeze

    params do
      required(:vendor_ref).hash
      required(:signal_code).filled(:string)
      required(:source_system).filled(:string)
      required(:source_event_id).filled(:string)
      optional(:value_numeric).maybe(:float)
      optional(:value_boolean).maybe(:bool)
      required(:recorded_at).filled(:string)
      optional(:window_start).maybe(:string)
      optional(:window_end).maybe(:string)
      optional(:context).maybe(:hash)
    end

    rule(:vendor_ref) do
      h = value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      tax_id       = h["tax_id"]
      normalized   = h["normalized_name"]
      source_ref   = h["source_system_ref"]

      if tax_id.to_s.strip.empty? &&
         normalized.to_s.strip.empty? &&
         source_ref.to_s.strip.empty?
        key.failure("MISSING_VENDOR_REF: vendor_ref must include at least one of " \
                    "tax_id, normalized_name, or source_system_ref")
      end
    end

    rule(:source_system) do
      unless VALID_SOURCE_SYSTEMS.include?(value.to_s)
        key.failure("source_system must be one of #{VALID_SOURCE_SYSTEMS.inspect}")
      end
    end

    rule(:signal_code) do
      definition = SignalDefinition.find_by(code: value.to_s)
      if definition.nil?
        key.failure("UNKNOWN_SIGNAL_CODE: #{value.inspect} not in signal_definitions")
      end
    end

    rule(:recorded_at) do
      parsed = safe_parse_time(value)
      if parsed.nil?
        key.failure("recorded_at must be ISO 8601")
      else
        now = Time.now.utc
        if parsed > (now + FUTURE_TOLERANCE_SECONDS)
          key.failure("FUTURE_TIMESTAMP: recorded_at is more than 1 hour in the future")
        end
        max_backfill = ENV.fetch("MAX_SIGNAL_BACKFILL_DAYS", "365").to_i
        if parsed < (now - (max_backfill * 86_400))
          key.failure("STALE_TIMESTAMP: recorded_at is older than #{max_backfill} days")
        end
      end
    end

    rule(:window_start, :window_end) do
      start_s = values[:window_start]
      end_s = values[:window_end]
      if start_s && end_s
        s = safe_parse_time(start_s)
        e = safe_parse_time(end_s)
        if s && e && e <= s
          key.failure("WINDOW_INVERTED: window_end (#{end_s}) must be after window_start (#{start_s})")
        end
      end
    end

    rule(:signal_code, :value_numeric, :value_boolean) do
      code = values[:signal_code]
      definition = SignalDefinition.find_by(code: code)
      next unless definition # UNKNOWN_SIGNAL_CODE already failed above

      vn = values[:value_numeric]
      vb = values[:value_boolean]

      case definition.value_type
      when "boolean"
        if vb.nil?
          key(:value_boolean).failure("boolean signal requires value_boolean")
        end
      when "rate"
        if vn.nil?
          key(:value_numeric).failure("numeric signal requires value_numeric")
        elsif vn.to_f < 0.0 || vn.to_f > 1.0
          key(:value_numeric).failure("VALUE_OUT_OF_RANGE: rate must be in [0.0, 1.0] (got #{vn})")
        end
      else # count, duration_seconds, money_cents
        if vn.nil?
          key(:value_numeric).failure("numeric signal requires value_numeric")
        elsif vn.to_f < 0.0
          key(:value_numeric).failure("VALUE_OUT_OF_RANGE: #{definition.value_type} must be >= 0 (got #{vn})")
        end
      end
    end

    # Class-level convenience: instantiate the contract and call with
    # the supplied payload. Every caller (ingester, REST controller)
    # uses `Ingestion::SignalValidator.call(payload)` — there is only
    # one contract instance per process and it is stateless.
    def self.call(payload)
      (@singleton ||= new).call(payload)
    end

    # Extract the canonical rejection reason (for storage in
    # vendor_signals.rejection_reason). Inspects the error messages for
    # a REASONS sentinel; falls back to VALIDATION_ERROR if none match.
    def self.rejection_reason_for(result)
      return nil if result.success?

      messages = result.errors.to_h.values.flatten.map(&:to_s).join(" | ")
      REASONS.each { |r| return r if messages.include?(r) }
      "VALIDATION_ERROR"
    end

    # ------------------------------------------------------------------

    private

    def safe_parse_time(str)
      Time.iso8601(str.to_s).utc
    rescue ArgumentError, TypeError
      nil
    end
  end
end
