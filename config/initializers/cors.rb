# frozen_string_literal: true

# CORS for the browser-facing API surface (`/api/*`).
#
# Allowed origins are driven by the `ALLOWED_ORIGINS` env var (PRD §14) — a
# comma-separated list of schemes+hosts. The production deploy sets this to the
# Operator UI origin; dev uses `http://localhost:3000`; tests use whatever
# `.env.local` provides (dotenv-rails loads it before this initializer runs).
#
# Rationale for inserting at position 0:
#
# - CORS headers must be emitted before Rack::Attack so that blocked preflights
#   still carry the right `Access-Control-*` headers (otherwise the browser
#   shows a misleading "CORS error" instead of the rate-limit JSON).
# - The exposed headers include Rack::Attack's rate-limit counters so the
#   Operator UI can surface remaining-quota UX without a separate request.

allowed_origins = ENV.fetch("ALLOWED_ORIGINS", "")
                     .split(",")
                     .map(&:strip)
                     .reject(&:empty?)

# Skip entirely when nothing is whitelisted — avoids registering a middleware
# that would match zero origins anyway, and keeps integration test output
# cleaner in environments that don't configure CORS.
if allowed_origins.any?
  Rails.application.config.middleware.insert_before 0, Rack::Cors do
    allow do
      origins(*allowed_origins)

      resource "/api/*",
        headers: :any,
        methods: %i[get post put patch delete options head],
        expose: %w[X-RateLimit-Remaining X-RateLimit-Reset],
        credentials: false,
        max_age: 3600
    end
  end
end
