# frozen_string_literal: true

# Rack::Attack baseline shell (PRD §8b / §10b).
#
# Stands up ONE shared throttle (`req/ip`) with a generous cap so abusive
# clients get a 429 before Sidekiq queues thrash — but without interfering
# with normal Operator UI / CI-bot traffic. Per-endpoint tuning (signal
# ingestion, report generation, alias review) lands in Phase 3 per the §8b
# rate-limit column.
#
# Storage: Redis when `REDIS_URL` is set (real behavior); MemoryStore fallback
# so test runs without Redis still execute. The compose stack always provides
# Redis, so the fallback is only exercised in exotic environments.
#
# 429 responses emit the canonical JSON:API error envelope (PRD §8b) so
# clients parse ONE shape across controller errors, middleware errors, and
# rate-limit errors. See `.claude/knowledge/foundation/api-error-response-shape.md`.

redis_url = ENV.fetch("REDIS_URL", "").to_s

Rack::Attack.cache.store = if redis_url.empty?
  ActiveSupport::Cache::MemoryStore.new
else
  ActiveSupport::Cache::RedisCacheStore.new(url: redis_url)
end

# Baseline: 600 req/min per IP. Covers the vast majority of legitimate usage
# (a human operator + one CI backfill) with ~10x headroom. Phase 3 narrows
# per endpoint (e.g. POST /api/signals → 1_200/min for batched ingestion).
Rack::Attack.throttle("req/ip", limit: 600, period: 60) do |req|
  req.ip
end

# Per-endpoint throttle: self-registration (PRD §5.1 + §8b) — 5/min/IP.
# Public endpoint with no auth; a tight per-IP cap prevents enumeration /
# slug-squatting. Scope narrows the matcher to POST /api/tenants/register
# only so other allowlisted routes aren't affected.
Rack::Attack.throttle("tenants/register/ip", limit: 5, period: 60) do |req|
  req.ip if req.path == "/api/tenants/register" && req.post?
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
    [body]
  ]
end
