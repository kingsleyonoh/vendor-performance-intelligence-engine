# frozen_string_literal: true

module Api
  # Tenant-resolving base class that every `Api::*Controller` inherits from.
  # Centralizes:
  #
  # - `render_api_error(code, status:, message:, details:)` helper emitting the
  #   PRD §8b `{error: {code, message, details?}}` envelope.
  # - `rescue_from` handlers for the common error shapes (ActiveRecord,
  #   ActionPolicy, generic StandardError).
  # - `require_tenant!` before_action that guarantees `Current.tenant` is set
  #   by the ApiKeyAuthenticator middleware (future Phase 1 batch).
  # - After-action audit hook that delegates to `Audit::Recorder` when the
  #   recorder is wired (future Batch 004). Currently a no-op so controllers
  #   built in Batch 003 don't fail open.
  #
  # See `.agent/knowledge/foundation/api-error-response-shape.md`,
  # `.agent/knowledge/foundation/tenant-scoping-pattern.md`, and
  # `.agent/knowledge/foundation/auth-guard-pattern.md` before subclassing.
  class BaseController < ActionController::API
    include ActionPolicy::Controller

    # ActionPolicy authorization targets. v1 has no per-tenant user model —
    # the API-key holder IS the admin (see Batch 007 DESIGN_DECISION).
    # `:user` is kept nullable (see ApplicationPolicy) so callers that have
    # no authenticated UI session still resolve. `:tenant` is the real
    # authorization context, read from Current.tenant.
    authorize :user, through: :current_user_for_policy
    authorize :tenant, through: :current_tenant

    # --------------------------------------------------------------------
    # Auth gate. ApiKeyAuthenticator middleware (Phase 1) sets Current.tenant
    # from the X-API-Key header BEFORE this before_action runs. If the
    # middleware did not set it — because the middleware is not yet installed,
    # because the key was invalid, or because the request bypassed the
    # allowlist incorrectly — we fail closed with UNAUTHORIZED.
    # --------------------------------------------------------------------
    before_action :capture_request_id
    before_action :require_tenant!

    # --------------------------------------------------------------------
    # Audit hook. Delegates to `Audit::Recorder` (lib/audit/recorder.rb,
    # wired in Batch 005). Runs only on mutating actions (create/update/
    # destroy). Audit failures log and swallow — never 500 a successful
    # request because audit couldn't write.
    # --------------------------------------------------------------------
    after_action :record_audit_trail, if: :mutating_action?

    # --------------------------------------------------------------------
    # Rescue handlers — ordering is LAST-REGISTERED-WINS in Rails, so the
    # generic StandardError handler must be registered FIRST. The domain-
    # specific handlers register after and therefore match before the
    # generic fallback.
    # --------------------------------------------------------------------
    rescue_from StandardError, with: :render_internal_error
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from ActiveRecord::RecordInvalid, with: :render_validation_error
    rescue_from ActiveRecord::RecordNotUnique, with: :render_conflict
    rescue_from ActionPolicy::Unauthorized, with: :render_forbidden

    # Render the canonical JSON:API error envelope (PRD §8b).
    #
    # - code: one of Errors::JsonApiError::ALL_CODES (string or symbol)
    # - status: optional HTTP status override; defaults to the mapping in
    #   JsonApiError.http_status_for(code)
    # - message: human-readable string; defaults to a generic per-code text
    # - details: optional array of { path:, issue: } hashes
    # ActionPolicy authorization context. Default `user` context is unused
    # in v1 (the API-key holder IS the admin — see Batch 007 design
    # decision). Policies declare `authorize :tenant, through: :current_tenant`
    # and read directly from `Current.tenant` where needed.
    def current_tenant
      Current.tenant
    end

    # API surface has no UI session user; return nil. ApplicationPolicy
    # declares `authorize :user, allow_nil: true` so this is safe.
    def current_user_for_policy
      nil
    end

    def render_api_error(code, status: nil, message: nil, details: nil)
      normalized_code = code.to_s.upcase
      http_status = status || Errors::JsonApiError.http_status_for(normalized_code)

      body = {
        error: {
          code: normalized_code,
          message: message || default_message_for(normalized_code)
        }
      }
      body[:error][:details] = details if details.present?

      render json: body, status: http_status
    end

    private

    def capture_request_id
      Current.request_id = request.request_id if Current.respond_to?(:request_id=)
    end

    # True for the three Rails RESTful mutating actions. Used by the
    # `record_audit_trail` after_action predicate — audit rows are only
    # written for state changes, not reads.
    # Auto-audited action names. The three RESTful mutators plus the
    # non-RESTful state-change actions used across VPI controllers
    # (alerts ack/suppress/retry, scoring rules activate, alias merge,
    # tenant key rotation). Non-listed action names that mutate state
    # MUST call `Audit::Recorder.record` explicitly inside the action
    # body (see lib/audit/recorder.rb usage examples).
    MUTATING_ACTION_NAMES = %w[
      create update destroy
      acknowledge suppress retry
      activate merge
    ].freeze

    def mutating_action?
      MUTATING_ACTION_NAMES.include?(action_name)
    end

    def require_tenant!
      return if Current.tenant.present?

      render_api_error(
        Errors::JsonApiError::UNAUTHORIZED,
        message: "Missing or invalid X-API-Key."
      )
    end

    def record_audit_trail
      return unless defined?(::Audit::Recorder)
      return unless response.successful?

      ::Audit::Recorder.record(
        actor: Current.tenant || "unauthenticated",
        action: "#{controller_name}##{action_name}",
        entity_type: controller_name.classify,
        entity_id: params[:id],
        tenant_id: Current.tenant&.id
      )
    rescue StandardError => e
      # The audit recorder is safety-critical but not request-critical. Log
      # and continue — never let an audit failure 500 a successful request.
      Rails.logger.error("Audit recorder failed: #{e.class}: #{e.message}")
    end

    def render_not_found(exception)
      render_api_error(
        Errors::JsonApiError::NOT_FOUND,
        message: exception.message.presence || "Resource not found."
      )
    end

    def render_validation_error(exception)
      details = exception.record.errors.map do |err|
        { path: err.attribute.to_s, issue: err.message }
      end

      render_api_error(
        Errors::JsonApiError::VALIDATION_ERROR,
        message: "Validation failed.",
        details: details
      )
    end

    def render_conflict(_exception)
      render_api_error(
        Errors::JsonApiError::CONFLICT,
        message: "Resource already exists or conflicts with current state."
      )
    end

    def render_forbidden(_exception)
      render_api_error(
        Errors::JsonApiError::FORBIDDEN,
        message: "You are not permitted to perform this action."
      )
    end

    def render_internal_error(exception)
      # Log full context server-side; scrub the response to a generic message.
      Rails.logger.error("Unhandled #{exception.class}: #{exception.message}")
      Rails.logger.error(exception.backtrace&.first(20)&.join("\n"))

      render_api_error(
        Errors::JsonApiError::INTERNAL_ERROR,
        message: "Something went wrong. Please try again or contact support."
      )
    end

    def default_message_for(code)
      {
        "VALIDATION_ERROR" => "Request payload is invalid.",
        "UNAUTHORIZED" => "Authentication required.",
        "FORBIDDEN" => "Not permitted.",
        "NOT_FOUND" => "Resource not found.",
        "CONFLICT" => "Resource conflict.",
        "RATE_LIMITED" => "Too many requests.",
        "INTERNAL_ERROR" => "Internal server error.",
        "SERVICE_UNAVAILABLE" => "Service temporarily unavailable."
      }.fetch(code, "Error")
    end
  end
end
