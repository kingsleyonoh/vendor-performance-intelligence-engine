# frozen_string_literal: true

# Rack::Attack — per-endpoint rate limits tuned to PRD §8b + §10b.
#
# Storage: Redis when `REDIS_URL` is set (real behavior); MemoryStore fallback
# so test runs without Redis still execute. Compose stack always provides Redis.
#
# Tier strategy (PRD §8b):
#   ┌─────────────────────────────┬───────────┬──────────────────────────────┐
#   │ Tier                        │ Limit/min │ Discriminator                │
#   ├─────────────────────────────┼───────────┼──────────────────────────────┤
#   │ tenants/register/ip         │ 5         │ req.ip (public, no tenant)   │
#   │ rotate_key/tenant           │ 2         │ X-API-Key (admin-grade)      │
#   │ signals/write/tenant        │ 600       │ X-API-Key (high-volume)      │
#   │ vendors/read/tenant         │ 200       │ X-API-Key                    │
#   │ vendors/write/tenant        │ 60        │ X-API-Key                    │
#   │ scoring_rules/write/tenant  │ 10        │ X-API-Key (rare admin)       │
#   │ reports/write/tenant        │ 20        │ X-API-Key (expensive)        │
#   └─────────────────────────────┴───────────┴──────────────────────────────┘
#
# Health (`/api/health*`) and Prometheus (`/metrics`) are safelisted — they
# are scraped every 15-60s by external probes and rate-limiting them would
# defeat the purpose of having uptime + APM telemetry.
#
# 429 responses emit the canonical PRD §8b error envelope so clients parse
# ONE shape across controller errors, middleware errors, and rate-limit errors.
# See `.claude/knowledge/foundation/api-error-response-shape.md`.

redis_url = ENV.fetch("REDIS_URL", "").to_s

Rack::Attack.cache.store = if redis_url.empty?
  ActiveSupport::Cache::MemoryStore.new
else
  ActiveSupport::Cache::RedisCacheStore.new(url: redis_url)
end

# ---------------------------------------------------------------------------
# Safelists — paths that MUST NEVER be throttled.
# ---------------------------------------------------------------------------

# Prometheus scrape endpoint. Self-hosted Prometheus polls /metrics every 15s.
# The path is Basic-Auth gated (see `app/controllers/metrics_controller.rb`)
# so this safelist is not a security relaxation.
Rack::Attack.safelist("metrics-scrape") do |req|
  req.path == "/metrics"
end

# Health check probes. BetterStack hits `/api/health/ready` every 60s.
# Throttling them would create false-positive uptime alerts. All four health
# endpoints (root, db, redis, ready) are public-allowlisted in the auth
# middleware too, so this is the matching middleware-tier exception.
Rack::Attack.safelist("health-checks") do |req|
  req.path.start_with?("/api/health")
end

# ---------------------------------------------------------------------------
# Public IP-scoped throttle: self-registration. PRD §5.1 + §8b.
# Tightest cap (5/min/IP) prevents enumeration / slug-squatting since this
# endpoint creates a tenant without prior auth.
#
# `RACK_ATTACK_REGISTER_LIMIT` lets the E2E rake task bump the cap for the
# booted Puma (every E2E test shares 127.0.0.1; 12+ tests register tenants
# in <60s, which exceeds 5/min). Production leaves the env unset so the
# default 5 applies — anti-enumeration unchanged.
# ---------------------------------------------------------------------------
register_limit = ENV.fetch("RACK_ATTACK_REGISTER_LIMIT", "5").to_i
Rack::Attack.throttle("tenants/register/ip", limit: register_limit, period: 60) do |req|
  req.ip if req.path == "/api/tenants/register" && req.post?
end

# ---------------------------------------------------------------------------
# Per-tenant tiers. Discriminator is `X-API-Key` (sufficient — abusive
# tenants get isolated; legitimate cross-IP usage by one tenant aggregates
# correctly). Each tier matches PRD §8b's published rate limits.
# ---------------------------------------------------------------------------

# Admin-grade: rotate API key. 2/min/tenant — tighter than any other write
# because each call invalidates the prior key (not something an automated
# system should ever do in a tight loop).
Rack::Attack.throttle("rotate_key/tenant", limit: 2, period: 60) do |req|
  api_key_discriminator(req) if req.path == "/api/tenants/me/rotate-key" && req.post?
end

# High-volume ingestion. 600/min/tenant — the single highest cap because
# a healthy tenant can legitimately push thousands of signals/hour during
# a backfill. POST /api/signals only (the from-hub endpoint is HMAC-auth
# and treated separately upstream).
Rack::Attack.throttle("signals/write/tenant", limit: 600, period: 60) do |req|
  api_key_discriminator(req) if req.path == "/api/signals" && req.post?
end

# Vendor reads — 200/min/tenant covers a procurement team's dashboard
# refresh + per-vendor drill-down without restraint.
Rack::Attack.throttle("vendors/read/tenant", limit: 200, period: 60) do |req|
  next unless req.get?

  api_key_discriminator(req) if vendors_path?(req.path)
end

# Vendor writes — 60/min/tenant. Includes POST/PATCH/DELETE on vendors
# and aliases. Bulk-edit operations should batch upstream.
Rack::Attack.throttle("vendors/write/tenant", limit: 60, period: 60) do |req|
  next if req.get?

  api_key_discriminator(req) if vendors_path?(req.path)
end

# Scoring rules writes — 10/min/tenant. Operator-grade infrequent admin.
Rack::Attack.throttle("scoring_rules/write/tenant", limit: 10, period: 60) do |req|
  next if req.get?

  api_key_discriminator(req) if req.path.start_with?("/api/scoring_rules") || req.path.start_with?("/api/scoring-rules")
end

# Report creation — 20/min/tenant. Expensive (PDF render, CSV aggregation),
# tighter cap discourages tab-spam and protects worker queue depth.
Rack::Attack.throttle("reports/write/tenant", limit: 20, period: 60) do |req|
  next if req.get?

  api_key_discriminator(req) if req.path.start_with?("/api/reports")
end

# ---------------------------------------------------------------------------
# Helpers — kept private to this initializer so callers can't depend on them.
# ---------------------------------------------------------------------------

# Use the X-API-Key header as the per-tenant discriminator. We hash to avoid
# putting a raw key into a cache key (defense-in-depth — Redis keys are
# observable in many ops dashboards). When no key is present, returns nil
# (request escapes the throttle and falls back to whatever auth gate the
# controller raises).
def api_key_discriminator(req)
  raw = req.get_header("HTTP_X_API_KEY")
  return nil if raw.nil? || raw.empty?

  Digest::SHA256.hexdigest(raw)[0, 16]
end

def vendors_path?(path)
  path.start_with?("/api/vendors")
end

# When throttled, emit the PRD §8b error envelope so clients don't need a
# second parser for 429s.
Rack::Attack.throttled_responder = lambda do |_request|
  body = {
    error: {
      code: "RATE_LIMITED",
      message: "Too many requests. Please slow down and retry."
    }
  }.to_json

  [
    429,
    {
      "Content-Type" => "application/json; charset=utf-8",
      "Content-Length" => body.bytesize.to_s
    },
    [ body ]
  ]
end
