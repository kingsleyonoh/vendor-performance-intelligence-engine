# frozen_string_literal: true

module Api
  module Signals
    # POST /api/signals/from-hub — PRD §5, §8, §13.2.
    #
    # Inbound HMAC-authenticated signal endpoint for Notification Hub
    # fanout events. Allowlisted in `Auth::ApiKeyAuthenticator::PUBLIC_ALLOWLIST_PATHS`,
    # so it does NOT use the X-API-Key middleware. Authentication is via
    # `Auth::HubHmacVerifier` (HMAC-SHA256 over `<timestamp>.<raw_body>`
    # using `HUB_INGRESS_SECRET`).
    #
    # Tenant resolution: the payload includes `tenant_slug`; the controller
    # looks up the tenant and binds `Current.tenant` for the duration of
    # this request.
    #
    # Inherits ActionController::API directly (NOT Api::BaseController) —
    # no tenant before_action, no API-key requirement. The custom error
    # envelope is rendered inline via `render_error`.
    class FromHubController < ActionController::API
      def create
        # 1. Verify HMAC signature.
        unless ::Auth::HubHmacVerifier.verify(request)
          return render_error(code: "INVALID_SIGNATURE", status: 401,
                              message: "Hub signature verification failed.")
        end

        # 2. Parse body (raw, since middleware bypassed Rails param parser).
        payload = parse_body
        slug = payload[:tenant_slug].to_s
        if slug.empty?
          return render_error(code: "VALIDATION_ERROR", status: 400,
                              message: "tenant_slug is required.",
                              details: [{ path: "tenant_slug", issue: "missing" }])
        end

        # 3. Resolve tenant by slug.
        tenant = ::Tenant.find_by(slug: slug)
        unless tenant
          return render_error(code: "INVALID_TENANT", status: 404,
                              message: "Unknown tenant_slug: #{slug}")
        end

        # 4. Bind Current.tenant for the duration of this request.
        ::Current.tenant = tenant

        # 5. Strip envelope keys before handing off to SignalIngester —
        # `tenant_slug` lives at the top level of the from-hub envelope
        # but is not part of the canonical signal schema.
        signal_payload = payload.except(:tenant_slug)

        result = ::Ingestion::SignalIngester.call(payload: signal_payload, tenant: tenant)

        case result[:status]
        when :ingested
          render json: { status: "accepted", signal_id: result[:signal]&.id }, status: :accepted
        when :deduped
          # Idempotent fanout — Hub re-deliveries land here. Return 202
          # with the existing row so the Hub records a successful ack.
          render json: { status: "deduped", signal_id: result[:signal]&.id }, status: :accepted
        when :rejected
          render_error(code: "VALIDATION_ERROR", status: 400,
                       message: "Signal rejected: #{result[:rejection_reason]}",
                       details: [{ path: "signal", issue: result[:rejection_reason] }])
        else
          render_error(code: "INTERNAL_ERROR", status: 500,
                       message: "Unexpected ingester result.")
        end
      ensure
        ::Current.tenant = nil if ::Current.respond_to?(:tenant=)
      end

      private

      def parse_body
        raw = request.raw_post.to_s
        return {} if raw.empty?
        ::JSON.parse(raw, symbolize_names: true)
      rescue ::JSON::ParserError
        {}
      end

      def render_error(code:, status:, message:, details: nil)
        body = { error: { code: code, message: message } }
        body[:error][:details] = details if details
        render json: body, status: status
      end
    end
  end
end
