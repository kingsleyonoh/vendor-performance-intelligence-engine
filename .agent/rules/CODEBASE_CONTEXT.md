# Vendor Performance Intelligence Engine — Codebase Context

> Last updated: 2026-04-25 (Phase 2 close-out + Mode C sync — ECOSYSTEM split)
> Template synced: 2026-04-25

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
| Templates (Hub) | Liquid 5.x (test group only — drives `test/fixtures/hub_templates/*.liquid` template-binding fixture tests) |
| PDF | WickedPDF (wkhtmltopdf wrapper) |
| UI | Tailwind CSS + ViewComponent (Hotwire: Turbo + Stimulus) |
| Hosting | Docker on Hetzner VPS (`vendors.kingsleyonoh.com`) |
| Deploy | docker-compose + Traefik + Let's Encrypt + GitHub Actions → GHCR |
| Observability | Sentry (errors), Axiom (logs via Lograge), BetterStack (uptime), Prometheus + Grafana (APM), PostHog (analytics) |
| Package Manager | Bundler |
| Build Tool | `bin/rails assets:precompile` |

## Project Structure

```
app/      — controllers (api/, settings/, UI), models, components, serializers, jobs, views
lib/      — auth, tenants, ingestion (+ mappers/), ecosystem, alerts, scoring, reports, cache, audit, errors, tasks
config/   — routes.rb, schedule.yml (sidekiq-cron), initializers/ (auto_boot, cors, rack_attack, lograge, sidekiq, ecosystem_clients, alert_dispatcher)
db/       — migrate/ (18+ migrations through Phase 3), seeds/{signal_definitions,scoring_rules}.yml, structure.sql
test/     — controllers, models, jobs, lib, integration, system, fixtures (+ hub_templates/), e2e_api, support, vcr_cassettes
docker/ + Dockerfile + docker-compose.yml + docker-compose.prod.yml
bin/      — dev, dc, rails, rake, rubocop, brakeman, setup, thrust
```

For per-file paths see `.agent/rules/CODEBASE_CONTEXT_ECOSYSTEM.md` Deep References table. Per-module summaries in `CODEBASE_CONTEXT_MODULES.md`; schema in `CODEBASE_CONTEXT_SCHEMA.md`. PRD §9 has the full tree with per-file annotations.

## Key Modules

See **`.agent/rules/CODEBASE_CONTEXT_MODULES.md`** for one-line summaries of each module (§5.1 Tenant/Auth, §5.2 Vendor/Alias, §5.3 Signal Ingestion, §5.4 Composite Scorer, §5.5 Risk Alert Router, §5.6 Reporting, §5.7 RAG Enrichment) plus the background-job table and shared-utility lifecycle rules.

Full module deep-dives live in `.agent/knowledge/modules/` — one file per module (created on first implementation touch).

## Database Schema

See **`.agent/rules/CODEBASE_CONTEXT_SCHEMA.md`** for the full table catalog (tenants, vendors, vendor_aliases, signal_definitions, vendor_signals, vendor_scores, scoring_rules, risk_alerts, vendor_reports, ingestion_sources, ingestion_runs, audit_log_entries), partitioning strategy, tenant identity columns (§4.T), and relationships diagram.

## Environment Variables

Full list (grouped by concern) in **`.agent/rules/CODEBASE_CONTEXT_ENV.md`**. Covers: Rails runtime, Database, Redis/Sidekiq, tenant management, auth/security, scoring tunables, setup automation, every ecosystem integration (`NOTIFICATION_HUB_*`, `WORKFLOW_ENGINE_*`, `WEBHOOK_ENGINE_*`, `INVOICE_RECON_*`, `CONTRACT_ENGINE_*`, `NATS_*`, `RECON_ENGINE_*`, `RAG_PLATFORM_*`), observability (`SENTRY_DSN`, `AXIOM_*`, `POSTHOG_*`, `PROMETHEUS_ENABLED`, `METRICS_BASIC_AUTH_*`), and report generation. Canonical source: `.env.example` + PRD §14.

## External Integrations, Notifications, Deep References, Observability

Pulled into **`.agent/rules/CODEBASE_CONTEXT_ECOSYSTEM.md`** to keep this file under the 10K rules-file cap. Contents:
- External Integrations / Ecosystem Connections table (PRD §6, §6b — 6 outbound adapters + 1 inbound HMAC ingress, all feature-flagged standalone-first)
- Notifications table (PRD §7b — 9 Hub templates, all bound to `DeliveryPayload` shape)
- Deep References table (every module → file paths)
- Observability table (PRD §10b — Sentry, Lograge, BetterStack, Prometheus, PostHog)

## Commands

> **Docker-mode dev loop.** This project has no host Ruby — every command runs inside the `dev` service defined in `docker-compose.yml`. `bin/dc` is a thin wrapper around `docker compose run --rm dev` (added in the dev-container SETUP batch). Host commands shown in parentheses as reference only.

| Action | Command (host) | Underlying |
|--------|---------------|------------|
| Open dev shell | `bin/dc bash` | `docker compose run --rm dev bash` |
| Dev server | `bin/dc bin/dev` | starts Puma + Sidekiq + Tailwind watcher inside `dev` service (port 3000 mapped to host) |
| Run tests | `bin/dc bin/rails test` | `docker compose run --rm dev bin/rails test` |
| Run tests (unit only) | `N/A` (project does not split unit/integration tiers) | YOLO sub-agents fall back to full tests + flag `no_test_tier_split` |
| Run tests (integration only) | `bin/dc bin/rails test` | duplicate of full test run; project's `test/` tree mixes unit + integration |
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
- **Middleware:** `lib/auth/api_key_authenticator.rb` (Rack middleware) — **LIVE** as of Phase 1. Public allowlist: `/api/tenants/register`, `/api/health/*`, `/api/signals/from-hub` (HMAC-verified). Resolves `Current.tenant` via 12-char prefix → constant-time SHA-256 compare, cached through `Cache::TenantCache`. `Tenants::CaptureSnapshot(tenant_id)` builds the immutable `TenantSnapshot` (§4.T) consumed by Phase 2 alert payloads + Phase 3 report render contexts.

## Key Patterns & Conventions

> Patterns catalog: `.agent/knowledge/patterns/_index.md` — one file per pattern. The six VPI architecture invariants are the canonical expression of "principles" and live in **PRD §2** (source of truth) + **`docs/progress.md`** Invariants banner (reviewer quick-reference) + **`.agent/rules/architecture_rules.md`** (enforcement). Do not re-state them here — keeps this file bounded and prevents drift.

## Gotchas & Lessons Learned

> Gotchas catalog: `.agent/knowledge/gotchas/_index.md` — one file per gotcha, `YYYY-MM-DD-slug.md`. Do not append rows to this file; directory-per-kind only.

## Shared Foundation (MUST READ before any implementation)

> Foundation primitives live in `.agent/knowledge/foundation/` — one file per primitive. See `foundation/_index.md` for the catalog. The AI MUST read the relevant files in full before writing any new code that touches the surface they establish.
