# frozen_string_literal: true

require "active_support/security_utils"

module Auth
  # Rack middleware that enforces VPI's primary architectural invariant:
  # every API request under `/api/*` resolves to a tenant via `X-API-Key`
  # (PRD §5.1, `.claude/rules/architecture_rules.md` — Tenant Scoping).
  #
  # Flow:
  #   1. If path is in PUBLIC_ALLOWLIST → pass through; `Current.tenant` stays nil.
  #   2. Otherwise require `X-API-Key` header.
  #   3. Take the first `Tenant::API_KEY_PREFIX_LENGTH` chars → api_key_prefix.
  #   4. Look up the tenant (cached via `Cache::TenantCache`, 60s TTL).
  #   5. Constant-time compare SHA-256(raw_key) against stored api_key_hash.
  #   6. On match + active → set `Current.tenant` and proceed.
  #   7. On match + inactive → 403 FORBIDDEN.
  #   8. Anything else → 401 UNAUTHORIZED.
  #
  # All error responses emit the PRD §8b JSON error envelope — the same shape
  # returned by `Api::BaseController#render_api_error`.
  #
  # Registered in `config/application.rb`.
  class ApiKeyAuthenticator
    # Paths that bypass this middleware. Order-preserved; a request path must
    # exactly match one entry (string) or match the regex. Keep this list
    # small — every entry is a security audit item.
    PUBLIC_ALLOWLIST_PATHS = [
      "/api/tenants/register",       # POST — self-registration (§5.1)
      "/api/health",                 # GET  — liveness
      "/api/health/db",              # GET  — DB probe
      "/api/health/redis",           # GET  — Redis probe
      "/api/health/ready",           # GET  — readiness
      "/api/signals/from-hub"        # POST — HMAC-authenticated ingress
    ].freeze

    API_PATH_PREFIX = "/api/"
    UNAUTHORIZED_CODE = "UNAUTHORIZED"
    FORBIDDEN_CODE = "FORBIDDEN"

    def initialize(app)
      @app = app
    end

    def call(env)
      request = ::Rack::Request.new(env)
      path = request.path

      # Scope: only /api/* routes are gated. UI routes pass through.
      return @app.call(env) unless path.start_with?(API_PATH_PREFIX)

      # Public allowlist.
      return @app.call(env) if PUBLIC_ALLOWLIST_PATHS.include?(path)

      raw_key = env["HTTP_X_API_KEY"].to_s.strip
      return error_response(UNAUTHORIZED_CODE, "API key required.") if raw_key.empty?

      tenant = resolve_tenant(raw_key)
      return error_response(UNAUTHORIZED_CODE, "Invalid API key.") unless tenant

      unless tenant.is_active
        return error_response(FORBIDDEN_CODE, "Tenant account is disabled.")
      end

      # Bind tenant for the duration of this request. Rails clears
      # CurrentAttributes between requests via an installed middleware;
      # we reset defensively on the way out too.
      Current.tenant = tenant
      Current.request_id = request.env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]

      @app.call(env)
    ensure
      Current.tenant = nil if Current.respond_to?(:tenant=)
    end

    private

    # Cached lookup. Returns a Tenant (AR-hydrated, not-new) or nil.
    #
    # Cache entry: `api_key_prefix -> tenant.attributes` hash. The whole row
    # is cached (60s TTL) so a second hit with the same key avoids the
    # Tenant SELECT entirely. On a rotate-key call, `Cache::TenantCache.delete`
    # wipes the old prefix entry so the old key stops authenticating
    # immediately without waiting for TTL expiry.
    #
    # The hash is still verified per request — the cache is a lookup
    # shortcut, never a security bypass.
    def resolve_tenant(raw_key)
      prefix = raw_key[0, Tenant::API_KEY_PREFIX_LENGTH]
      return nil if prefix.to_s.length < Tenant::API_KEY_PREFIX_LENGTH

      cached_attrs = ::Cache::TenantCache.get(prefix)

      tenant =
        if cached_attrs.is_a?(Hash) && cached_attrs["api_key_prefix"] == prefix
          Tenant.instantiate(cached_attrs)
        else
          found = Tenant.find_by(api_key_prefix: prefix)
          ::Cache::TenantCache.set(prefix, found.attributes) if found
          found
        end

      return nil unless tenant

      provided_hash = ::Digest::SHA256.hexdigest(raw_key)
      return nil unless ::ActiveSupport::SecurityUtils.secure_compare(provided_hash, tenant.api_key_hash.to_s)

      tenant
    end

    def error_response(code, message)
      body = {
        error: {
          code: code,
          message: message
        }
      }.to_json

      status = ::Errors::JsonApiError.http_status_for(code)
      [
        status,
        {
          "Content-Type" => "application/json; charset=utf-8",
          "Content-Length" => body.bytesize.to_s
        },
        [body]
      ]
    end
  end
end
