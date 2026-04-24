# frozen_string_literal: true

module Errors
  # Canonical error-code taxonomy for VPI's JSON:API-style error envelope
  # (PRD §8b). Bound by every controller, every Rack middleware, and every
  # 429/5xx responder.
  #
  # Body shape:
  #
  #   {
  #     "error": {
  #       "code":    "VALIDATION_ERROR",
  #       "message": "Human-readable message",
  #       "details": [{ "path": "...", "issue": "..." }]
  #     }
  #   }
  #
  # See `.agent/knowledge/foundation/api-error-response-shape.md` for the full
  # contract (when each code applies, rules about 403-vs-404 cross-tenant, etc.)
  module JsonApiError
    VALIDATION_ERROR    = "VALIDATION_ERROR".freeze
    UNAUTHORIZED        = "UNAUTHORIZED".freeze
    FORBIDDEN           = "FORBIDDEN".freeze
    NOT_FOUND           = "NOT_FOUND".freeze
    CONFLICT            = "CONFLICT".freeze
    RATE_LIMITED        = "RATE_LIMITED".freeze
    INTERNAL_ERROR      = "INTERNAL_ERROR".freeze
    SERVICE_UNAVAILABLE = "SERVICE_UNAVAILABLE".freeze

    HTTP_STATUS = {
      VALIDATION_ERROR    => 400,
      UNAUTHORIZED        => 401,
      FORBIDDEN           => 403,
      NOT_FOUND           => 404,
      CONFLICT            => 409,
      RATE_LIMITED        => 429,
      INTERNAL_ERROR      => 500,
      SERVICE_UNAVAILABLE => 503
    }.freeze

    ALL_CODES = HTTP_STATUS.keys.freeze

    # Map a code (string or symbol) to its HTTP status. Raises ArgumentError
    # for unknown/blank codes — callers must fail loud rather than silently
    # return 500 for a typo.
    def self.http_status_for(code)
      raise ArgumentError, "code cannot be blank" if code.nil? || code.to_s.empty?

      normalized = code.to_s.upcase
      HTTP_STATUS.fetch(normalized) do
        raise ArgumentError, "unknown JsonApiError code: #{code.inspect}"
      end
    end
  end
end
