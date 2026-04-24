# frozen_string_literal: true

module Api
  # Ingestion endpoint for vendor signals — PRD §5.3, §8b.
  #
  # Accepts both single-signal and batch-signal shapes:
  #
  #   Single: JSON body is a signal payload (vendor_ref, signal_code, ...)
  #     → 201 { signal: <serialized> }
  #     → 400 / 422 on validation failure
  #
  #   Batch: JSON body is `{ signals: [<payload>, ...] }`
  #     → 202 { accepted_count, rejected_count, deduped_count, results }
  #     → 400 if size exceeds INGESTION_BATCH_SIZE
  #
  # Auth: `X-API-Key` via middleware → `Current.tenant`. Cross-tenant isolation:
  # each signal resolves a vendor under the CALLER's tenant (via
  # `Ingestion::VendorResolver`). A payload referencing "tenant B's vendor" by
  # tax_id or name simply creates / reuses a caller-tenant-scoped vendor —
  # the resolver cannot leak across tenants.
  #
  # Rate limit: 600/min baseline (per-endpoint tuning is Phase 3 per §8b).
  class SignalsController < ::Api::BaseController
    # Per-request cap. Defaults to PRD's recommended 100.
    def self.max_batch_size
      ENV.fetch("INGESTION_BATCH_SIZE", "100").to_i
    end

    def create
      parsed = parsed_body
      signals = extract_signals(parsed)

      if batch?(parsed)
        return render_batch(signals)
      end

      # Single signal path.
      result = ::Ingestion::SignalIngester.call(payload: parsed, tenant: Current.tenant)

      case result[:status]
      when :ingested
        render json: { signal: ::VendorSignalSerializer.new(result[:signal]).serializable_hash },
               status: :created
      when :deduped
        # Silent dedup for singles returns the existing row as 200 OK.
        render json: { signal: ::VendorSignalSerializer.new(result[:signal]).serializable_hash },
               status: :ok
      when :rejected
        render_api_error(
          ::Errors::JsonApiError::VALIDATION_ERROR,
          message: "Signal rejected: #{result[:rejection_reason]}",
          details: [{ path: "signal", issue: result[:rejection_reason] }]
        )
      else
        render_api_error(::Errors::JsonApiError::INTERNAL_ERROR,
                         message: "Unexpected ingester result")
      end
    rescue JSON::ParserError
      render_api_error(::Errors::JsonApiError::VALIDATION_ERROR,
                       message: "Request body is not valid JSON.")
    end

    private

    def batch?(parsed)
      parsed.is_a?(Hash) && parsed.key?(:signals)
    end

    def extract_signals(parsed)
      return [] unless batch?(parsed)

      Array(parsed[:signals])
    end

    def render_batch(signals)
      max = self.class.max_batch_size
      if signals.size > max
        return render_api_error(
          ::Errors::JsonApiError::VALIDATION_ERROR,
          message: "Batch exceeds max size of #{max} signals (got #{signals.size}).",
          details: [{ path: "signals", issue: "BATCH_TOO_LARGE" }]
        )
      end

      results = signals.map do |payload|
        ingester_result = ::Ingestion::SignalIngester.call(payload: payload, tenant: Current.tenant)
        serialize_result(ingester_result)
      end

      accepted = results.count { |r| r[:status] == "ingested" }
      deduped  = results.count { |r| r[:status] == "deduped" }
      rejected = results.count { |r| r[:status] == "rejected" }

      render json: {
        accepted_count: accepted,
        rejected_count: rejected,
        deduped_count: deduped,
        results: results
      }, status: :accepted
    end

    def serialize_result(result)
      case result[:status]
      when :ingested
        { status: "ingested", signal_id: result[:signal]&.id }
      when :deduped
        { status: "deduped", signal_id: result[:signal]&.id }
      when :rejected
        { status: "rejected", rejection_reason: result[:rejection_reason] }
      else
        { status: "error" }
      end
    end

    # Parse JSON body regardless of Rails' param-parser state.
    def parsed_body
      raw = request.request_parameters
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)

      # When the body is a top-level array wrapped in `_json` by Rails,
      # or a hash, hand it back deep-symbolized.
      if raw.is_a?(Hash) && raw.key?("_json")
        { signals: Array(raw["_json"]) }.deep_symbolize_keys
      else
        raw.deep_symbolize_keys
      end
    rescue StandardError
      {}
    end
  end
end
