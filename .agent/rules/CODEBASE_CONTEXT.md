# Vendor Performance Intelligence Engine — Codebase Context

> Last updated: 2026-04-23
> Template synced: 2026-04-23

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Ruby 3.3 |
| Framework | Rails 8.0 (API + Hotwire UI) |
| Database | PostgreSQL 16 (with `pg_partman` for `vendor_signals` monthly partitions) |
| Cache / Jobs | Redis 7 + Sidekiq 7 |
| Messaging | NATS JetStream (via `nats-pure`) — Contract Lifecycle subscriber |
| HTTP Client | Faraday 2 (with retry middleware + circuit breaker per adapter) |
| Auth (API) | Custom Rack middleware `lib/auth/api_key_authenticator.rb` — `X-API-Key` → `Current.tenant` |
| Auth (UI) | Rails 8 built-in (email + password) |
| Authorization | ActionPolicy (policy per resource in `app/policies/`) |
| Serializer | Alba |
| Validation | dry-validation 1.x (non-model inputs) |
| Test Runner | Minitest + Capybara + Playwright (system tests) |
| PDF | WickedPDF (wkhtmltopdf wrapper) |
| UI | Tailwind CSS + ViewComponent (Hotwire: Turbo + Stimulus) |
| Hosting | Docker on Hetzner VPS (`vendors.kingsleyonoh.com`) |
| Deploy | docker-compose + Traefik + Let's Encrypt + GitHub Actions → GHCR |
| Observability | Sentry (errors), Axiom (logs via Lograge), BetterStack (uptime), Prometheus + Grafana (APM), PostHog (analytics) |
| Package Manager | Bundler |
| Build Tool | `bin/rails assets:precompile` |

## Project Structure

```
app/ (controllers/api/+ui/, models/, jobs/, policies/, serializers/, components/, views/)
lib/ (tenants/, alerts/, ingestion/, scoring/, ecosystem/, reports/, auth/, audit/)
config/ (routes.rb, initializers/, schedule.yml)
db/ (migrate/, seeds/signal_definitions.yml)
test/ (controllers/, models/, jobs/, lib/, integration/, system/, fixtures/, e2e_api/, support/)
docker/ (Dockerfile, docker-compose.yml, docker-compose.prod.yml)
```

See PRD §9 for the full tree with per-file annotations. Per-module summaries in `.agent/rules/CODEBASE_CONTEXT_MODULES.md`; schema details in `.agent/rules/CODEBASE_CONTEXT_SCHEMA.md`.

## Key Modules

See **`.agent/rules/CODEBASE_CONTEXT_MODULES.md`** for one-line summaries of each module (§5.1 Tenant/Auth, §5.2 Vendor/Alias, §5.3 Signal Ingestion, §5.4 Composite Scorer, §5.5 Risk Alert Router, §5.6 Reporting, §5.7 RAG Enrichment) plus the background-job table and shared-utility lifecycle rules.

Full module deep-dives live in `.agent/knowledge/modules/` — one file per module (created on first implementation touch).

## Database Schema

See **`.agent/rules/CODEBASE_CONTEXT_SCHEMA.md`** for the full table catalog (tenants, vendors, vendor_aliases, signal_definitions, vendor_signals, vendor_scores, scoring_rules, risk_alerts, vendor_reports, ingestion_sources, ingestion_runs, audit_log), partitioning strategy, tenant identity columns (§4.T), and relationships diagram.

## Environment Variables

Full list (grouped by concern) in **`.agent/rules/CODEBASE_CONTEXT_ENV.md`**. Covers: Rails runtime, Database, Redis/Sidekiq, tenant management, auth/security, scoring tunables, setup automation, every ecosystem integration (`NOTIFICATION_HUB_*`, `WORKFLOW_ENGINE_*`, `WEBHOOK_ENGINE_*`, `INVOICE_RECON_*`, `CONTRACT_ENGINE_*`, `NATS_*`, `RECON_ENGINE_*`, `RAG_PLATFORM_*`), observability (`SENTRY_DSN`, `AXIOM_*`, `POSTHOG_*`, `PROMETHEUS_ENABLED`, `METRICS_BASIC_AUTH_*`), and report generation. Canonical source: `.env.example` + PRD §14.

## External Integrations / Ecosystem Connections (PRD §6, §6b)

All integrations are OPTIONAL (standalone-first — PRD §2.2). Each gated by `{SERVICE}_ENABLED=false` default.

| Direction | Service | Method | Purpose | Auth |
|-----------|---------|--------|---------|------|
| this → | Notification Hub | REST `POST /api/events` | Risk-band-change alerts (email + Telegram) | `X-API-Key` |
| this → | Workflow Automation Engine | REST `POST /api/workflows/:id/execute` | HIGH/CRITICAL escalations | `X-API-Key` |
| ← this | Webhook Ingestion Engine | REST pull (`/api/sources`, `/api/dead-letters`, `/api/stats`) | Integration-reliability signals | `X-API-Key` |
| ← this | Invoice Reconciliation Engine | Hub event subscribe (`invoice.*`) + REST pull | Financial signals | `X-API-Key` |
| ← this | Contract Lifecycle Engine | NATS JetStream subscribe (`contract.obligation.*`) + REST pull | Contractual signals | NATS creds + `X-API-Key` |
| ← this | Transaction Reconciliation Engine | REST pull `GET /api/v1/discrepancies?source=vendor` | Transactional signals | `X-API-Key` |
| ← this | Multi-Agent RAG Platform | REST pull `GET /api/graph/entities` | Vendor background enrichment | `X-API-Key` |
| → this | Hub event ingress (engine-hosted) | Inbound `POST /api/signals/from-hub` | Hub fanout into engine | Shared secret (HMAC) |

## Commands

> **Docker-mode dev loop.** This project has no host Ruby — every command runs inside the `dev` service defined in `docker-compose.yml`. `bin/dc` is a thin wrapper around `docker compose run --rm dev` (added in the dev-container SETUP batch).

| Action | Command (host) | Underlying |
|--------|---------------|------------|
| Open dev shell | `bin/dc bash` | `docker compose run --rm dev bash` |
| Dev server | `bin/dc bin/dev` | starts Puma + Sidekiq + Tailwind watcher inside `dev` service (port 3000 mapped to host) |
| Run tests | `bin/dc bin/rails test` | `docker compose run --rm dev bin/rails test` |
| System / UI tests | `bin/dc bin/rails test:system` | Playwright driven from inside `dev` service (Chromium installed in image) |
| E2E tests | `bin/dc bin/rake test:e2e` | boots Puma in the dev service then runs `test/e2e_api/*_test.rb` |
| Lint | `bin/dc bundle exec rubocop` | |
| Build | `bin/dc bundle install && bin/dc bin/rails assets:precompile` | |
| Migrate DB | `bin/dc bin/rails db:migrate` | Postgres runs in its own compose service on the same network |
| Seed DB | `bin/dc bin/rails db:seed` | |
| First-run setup | `bin/dc bin/rails vpi:setup` | |
| Start infra | `docker compose up -d postgres redis` | `nats` added when `NATS_ENABLED=true` |
| Stop infra | `docker compose down` | |
| Check infra | `docker compose ps` | |
| Verify toolchain | `docker compose run --rm dev ruby -v && docker compose run --rm dev bundle -v` | run once after the dev-container batch lands |

## Tenant Model

- **One API key per tenant.** `X-API-Key` header → take first 12 chars (`api_key_prefix`) → query `tenants` → constant-time SHA-256 compare against `api_key_hash` → set `Current.tenant` (Rails `CurrentAttributes`, thread-local).
- **Self-registration:** `POST /api/tenants/register` (rate-limited 5/min/IP, gated by `SELF_REGISTRATION_ENABLED`). Returns raw key ONCE; SHA-256 stored.
- **Tenant identity columns** (§4.T): `legal_name`, `full_legal_name`, `display_name`, `address`, `registration`, `contact`, `wordmark_url`, `brand_primary_hex`, `brand_accent_hex`, `locale`, `timezone` — all on the `tenants` row, bound by every PDF + email + Hub payload.
- **Middleware:** `lib/auth/api_key_authenticator.rb` (Rack middleware). Public allowlist: `/api/tenants/register`, `/api/health/*`, `/api/signals/from-hub` (HMAC-verified).

## Key Patterns & Conventions

> Patterns catalog: `.agent/knowledge/patterns/_index.md` — one file per pattern. The six VPI architecture invariants are the canonical expression of "principles" and live in **PRD §2** (source of truth) + **`docs/progress.md`** Invariants banner (reviewer quick-reference) + **`.agent/rules/architecture_rules.md`** (enforcement). Do not re-state them here — keeps this file bounded and prevents drift.

## Deep References

| Topic | Where to look |
|-------|--------------|
| Auth | `lib/auth/` + `app/controllers/api/base_controller.rb` |
| Scoring | `lib/scoring/` |
| Ingestion | `lib/ingestion/` |
| Ecosystem clients | `lib/ecosystem/` |
| Reports | `lib/reports/` |
| Alerts | `lib/alerts/` + `app/jobs/alerts/` |
| Tenant snapshot | `lib/tenants/capture_snapshot.rb` |
| UI | `app/views/` + `app/components/` |
| Architecture rules | `.agent/rules/architecture_rules.md` |

## Observability (PRD §10b)

| Concern | Tool |
|---------|------|
| Error tracking | Sentry (`SENTRY_DSN`) |
| Logging | Axiom via Lograge (structured JSON) |
| Uptime monitoring | BetterStack — probes `/api/health/ready` every 60s |
| APM | Prometheus + Grafana (self-hosted on VPS; scrape `/metrics`, Basic Auth via `METRICS_BASIC_AUTH_USER/PASS`) |
| Product analytics | PostHog (self-hosted). Events: `vendor_viewed`, `alert_acknowledged`, `scoring_rule_activated`, `report_generated`, `api_key_rotated` |

Health checks: `/api/health`, `/api/health/db`, `/api/health/redis`, `/api/health/ready`.

## Notifications (PRD §7b)

All notifications route via **Notification Hub** (no direct Resend/Twilio/Telegram integration). Templates registered via `notification-hub-onboard` skill:

| Template | Trigger |
|----------|---------|
| `vpi-risk-escalation-email` | Any → HIGH |
| `vpi-risk-critical-email` | Any → CRITICAL |
| `vpi-risk-escalation-telegram` | Any → HIGH |
| `vpi-risk-critical-telegram` | Any → CRITICAL |
| `vpi-risk-medium-email` | LOW → MEDIUM |
| `vpi-risk-improvement-digest` | Daily digest of improvements |
| `vpi-report-ready` | Report status → `ready` |
| `vpi-ingestion-stale` | `ingestion_sources.last_successful_pull > 24h` |
| `vpi-alias-review` | Pending alias queue > 20 |

All templates bind to `DeliveryPayload` shape (§5.5) — frozen at alert creation, never re-queried.

## Gotchas & Lessons Learned

> Gotchas catalog: `.agent/knowledge/gotchas/_index.md` — one file per gotcha, `YYYY-MM-DD-slug.md`. Do not append rows to this file; directory-per-kind only.

## Shared Foundation (MUST READ before any implementation)

> Foundation primitives live in `.agent/knowledge/foundation/` — one file per primitive. See `foundation/_index.md` for the catalog. The AI MUST read the relevant files in full before writing any new code that touches the surface they establish.
