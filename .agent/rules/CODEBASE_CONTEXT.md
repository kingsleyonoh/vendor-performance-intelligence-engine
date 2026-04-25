# Vendor Performance Intelligence Engine — Codebase Context

> Last updated: 2026-04-25 (Phase 2 close-out)
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
app/
  controllers/ (application_controller, dashboard_controller, vendors_controller, alerts_controller, sessions_controller, passwords_controller;
                api/{base,health,signals,vendors,vendor_aliases,scoring_rules,alerts}_controller,
                api/tenants/{registrations,me,rotate_key},
                api/vendors/{scores,signals,merge},
                api/signals/from_hub_controller,
                api/ingestion/{sources,runs}_controller + api/ingestion/sources/pull_now_controller,
                settings/ingestion_sources_controller)
  models/ (application_record, current, user, session, tenant, vendor, vendor_alias, signal_definition, vendor_signal, vendor_score, scoring_rule, risk_alert, ingestion_source, ingestion_run)
  components/ (auth/login_form, layouts/{top_nav,sidebar}, dashboard/{kpi_card,band_change_list}, vendors/{header,band_pill,vendor_row,filter_panel,score_history_chart,contributor_table,signal_timeline,alias_card}, alerts/{band_change_pill,inbox_row}, settings/{ingestion_source_form,ingestion_source_row,run_history_table})
  serializers/ (tenant, vendor, vendor_alias, vendor_signal, vendor_score, scoring_rule)
  jobs/ (application_job, score_recompute_job, partition_manager_job, alerts/{hub_dispatch,workflow_escalation,failed_alert_retry}, ingestion/{webhook_engine_signal_pull,invoice_recon_backfill,contract_lifecycle_backfill,contract_lifecycle_nats_consumer,transaction_recon_backfill}, monitors/stale_ingestion_monitor)
  helpers/, mailers/, channels/, views/
  (policies/, reports/ — arrive Phase 3+)
lib/
  auth/ (api_key_authenticator.rb — Rack middleware, LIVE; hub_hmac_verifier.rb — verifies inbound `/api/signals/from-hub`, LIVE)
  tenants/ (capture_snapshot.rb, api_key_generator.rb, registration_contract.rb)
  ingestion/ (name_normalizer, vendor_resolver, signal_validator, signal_ingester, vendor_merger; mappers/{webhook_engine,invoice_recon,contract_engine,recon_engine}_mapper — adapter payload → signal envelope, LIVE)
  ecosystem/ (hub_client, workflow_client, webhook_engine_client, invoice_recon_client, contract_engine_client, recon_engine_client, nats_connection, circuit_breaker — all LIVE; pure outbound clients, no app/ deps)
  alerts/ (capture_payload — freezes `risk_alerts.delivery_payload` at insert; dispatcher — emits via `Ecosystem::HubClient`)
  scoring/ (composite_scorer, aggregator, signal_scalers, time_decay, band_classifier, rule_previewer, rules_contract)
  cache/ (request_cache, scoring_config_cache, tenant_cache)
  audit/ (recorder.rb — Lograge-tagged JSON; DB insert wires Phase 3)
  errors/ (json_api_error.rb)
  tasks/ (test.rake, vpi.rake)
  (reports/ — pending Phase 3+)
config/ (routes.rb, schedule.yml — sidekiq-cron schedule for 7 jobs; initializers/ — auto_boot, cors, rack_attack, lograge, sidekiq, request_id_instrumentation, signal_ingester_hooks, ecosystem_clients)
db/ (migrate/ — 16 migrations through Phase 2; seeds/signal_definitions.yml)
test/ (controllers/, models/, jobs/, lib/, integration/, system/, fixtures/ + fixtures/hub_templates/{9 *.liquid templates}, e2e_api/, support/, vcr_cassettes/{hub_client,workflow_client,webhook_engine_client,invoice_recon_client,contract_engine_client,recon_engine_client})
docker/ + Dockerfile + docker-compose.yml + docker-compose.prod.yml
bin/ (dev, dc, rails, rake, rubocop, brakeman, setup, thrust)
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

| Direction | Service | Method | Status | Auth |
|-----------|---------|--------|--------|------|
| this → | Notification Hub | REST `POST /api/events` via `Ecosystem::HubClient` | **LIVE** (Phase 2) — feature-flagged | `X-API-Key` |
| this → | Workflow Automation Engine | REST `POST /api/workflows/:id/execute` via `Ecosystem::WorkflowClient` | **LIVE** (Phase 2) — feature-flagged | `X-API-Key` |
| ← this | Webhook Ingestion Engine | REST pull via `Ecosystem::WebhookEngineClient` + `Ingestion::WebhookEngineSignalPullJob` (every 10 min) | **LIVE** (Phase 2) — feature-flagged | `X-API-Key` |
| ← this | Invoice Reconciliation Engine | Hub event ingress + REST pull via `Ecosystem::InvoiceReconClient` + `Ingestion::InvoiceReconBackfillJob` (every 15 min) | **LIVE** (Phase 2) — feature-flagged | `X-API-Key` |
| ← this | Contract Lifecycle Engine | NATS JetStream subscribe via `Ingestion::ContractLifecycleNatsConsumerJob` + REST catch-up via `Ingestion::ContractLifecycleBackfillJob` (every 15 min) | **LIVE** (Phase 2) — feature-flagged | NATS creds + `X-API-Key` |
| ← this | Transaction Reconciliation Engine | REST pull via `Ecosystem::ReconEngineClient` + `Ingestion::TransactionReconBackfillJob` (every 15 min) | **LIVE** (Phase 2) — feature-flagged | `X-API-Key` |
| ← this | Multi-Agent RAG Platform | REST pull `GET /api/graph/entities` | Pending Phase 3 | `X-API-Key` |
| → this | Hub event ingress (engine-hosted) | Inbound `POST /api/signals/from-hub` — verified by `lib/auth/hub_hmac_verifier.rb` | **LIVE** (Phase 2) | Shared secret (HMAC) |

All outbound clients share `lib/ecosystem/circuit_breaker.rb` (Faraday middleware) and lifecycle-managed singletons in `config/initializers/ecosystem_clients.rb`. Inbound HMAC ingress is allowlisted in `Auth::ApiKeyAuthenticator`. VCR cassettes for all six outbound adapters under `test/vcr_cassettes/`.

## Commands

> **Docker-mode dev loop.** This project has no host Ruby — every command runs inside the `dev` service defined in `docker-compose.yml`. `bin/dc` is a thin wrapper around `docker compose run --rm dev` (added in the dev-container SETUP batch). Host commands shown in parentheses as reference only.

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
- **Middleware:** `lib/auth/api_key_authenticator.rb` (Rack middleware) — **LIVE** as of Phase 1. Public allowlist: `/api/tenants/register`, `/api/health/*`, `/api/signals/from-hub` (HMAC-verified). Resolves `Current.tenant` via 12-char prefix → constant-time SHA-256 compare, cached through `Cache::TenantCache`. `Tenants::CaptureSnapshot(tenant_id)` builds the immutable `TenantSnapshot` (§4.T) consumed by Phase 3 alert/report payloads.

## Key Patterns & Conventions

> Patterns catalog: `.agent/knowledge/patterns/_index.md` — one file per pattern. The six VPI architecture invariants are the canonical expression of "principles" and live in **PRD §2** (source of truth) + **`docs/progress.md`** Invariants banner (reviewer quick-reference) + **`.agent/rules/architecture_rules.md`** (enforcement). Do not re-state them here — keeps this file bounded and prevents drift.

## Deep References

| Topic | Where to look |
|-------|--------------|
| API base / CORS / rate-limit | `app/controllers/api/base_controller.rb` + `config/initializers/{cors,rack_attack}.rb` (rack_attack throttles `/api/tenants/register` to 5/min/IP) |
| API-key auth | `lib/auth/api_key_authenticator.rb` (LIVE) + `lib/cache/tenant_cache.rb` |
| Hub HMAC verifier | `lib/auth/hub_hmac_verifier.rb` — verifies inbound `POST /api/signals/from-hub` (allowlisted) |
| UI auth (Rails 8 built-in) | `app/controllers/concerns/authentication.rb` + `sessions_controller.rb` + `passwords_controller.rb` + `app/models/{user,session,current}.rb` |
| Tenant snapshot | `lib/tenants/{capture_snapshot,api_key_generator,registration_contract}.rb` (LIVE) |
| Scoring | `lib/scoring/` — `composite_scorer`, `aggregator`, `signal_scalers`, `time_decay`, `band_classifier`, `rule_previewer`, `rules_contract` (LIVE) |
| Ingestion | `lib/ingestion/` — `name_normalizer`, `vendor_resolver`, `signal_validator`, `signal_ingester`, `vendor_merger` (LIVE) |
| Ingestion adapters / mappers | `lib/ecosystem/{webhook_engine,invoice_recon,contract_engine,recon_engine}_client.rb` paired with `lib/ingestion/mappers/{webhook_engine,invoice_recon,contract_engine,recon_engine}_mapper.rb` (adapter response → signal envelope) — driven by `app/jobs/ingestion/*_backfill_job.rb` + `contract_lifecycle_nats_consumer_job.rb` |
| Ecosystem clients | `lib/ecosystem/` — `hub_client`, `workflow_client`, `webhook_engine_client`, `invoice_recon_client`, `contract_engine_client`, `recon_engine_client`, `nats_connection`, `circuit_breaker` (LIVE; pure outbound, lifecycle-managed in `config/initializers/ecosystem_clients.rb`) |
| Alerts | `lib/alerts/{capture_payload,dispatcher}.rb` + `app/jobs/alerts/{hub_dispatch,workflow_escalation,failed_alert_retry}_job.rb` + `app/controllers/{alerts_controller,api/alerts_controller}.rb` + `app/components/alerts/` (LIVE) |
| Ingestion management UI/API | `app/controllers/api/ingestion/{sources,runs}_controller.rb` + `app/controllers/api/ingestion/sources/pull_now_controller.rb` + `app/controllers/settings/ingestion_sources_controller.rb` + `app/components/settings/` |
| Errors | `lib/errors/json_api_error.rb` (JSON:API-style error envelope) |
| Cache helpers | `lib/cache/{request_cache,scoring_config_cache,tenant_cache}.rb` |
| Audit | `lib/audit/recorder.rb` — Lograge-tagged JSON (DB insert wires Phase 3) |
| Structured logging | `config/initializers/lograge.rb` + `request_id_instrumentation.rb` |
| Sidekiq config | `config/initializers/sidekiq.rb` + `Procfile.dev` + `config/schedule.yml` (sidekiq-cron schedules: `partition_manager` 01:00 UTC, `failed_alert_retry` every 30 min, `webhook_engine_signal_pull` every 10 min, `invoice_recon_backfill` / `contract_lifecycle_backfill` / `transaction_recon_backfill` every 15 min, `stale_ingestion_monitor` hourly) |
| UI (dashboard, vendors list, vendor detail, alerts inbox, settings, login) | `app/controllers/{dashboard,vendors,alerts}_controller.rb` + `app/controllers/settings/ingestion_sources_controller.rb` + `app/components/{auth,layouts,dashboard,vendors,alerts,settings}/` |
| Reports (pending) | `lib/reports/` (Phase 3) |
| Architecture rules | `.agent/rules/architecture_rules.md` |

## Observability (PRD §10b)

| Concern | Tool |
|---------|------|
| Error tracking | Sentry (`SENTRY_DSN`) — gem installed (`sentry-ruby`, `sentry-rails`); DSN wiring pending Phase 3 |
| Logging | Lograge ACTIVE — JSON formatter, emits `request_id`, `tenant_id`, `user_id`, `params`, `exception` (`config/initializers/lograge.rb`). `lib/audit/recorder.rb` ALSO emits Lograge-tagged JSON for mutations. Axiom token/dataset wiring pending Phase 3. |
| Uptime monitoring | BetterStack — probes `/api/health/ready` every 60s |
| APM | Prometheus + Grafana (self-hosted on VPS; scrape `/metrics`, Basic Auth via `METRICS_BASIC_AUTH_USER/PASS`) |
| Product analytics | PostHog (self-hosted). Events: `vendor_viewed`, `alert_acknowledged`, `scoring_rule_activated`, `report_generated`, `api_key_rotated` |

Health checks: `/api/health`, `/api/health/db`, `/api/health/redis`, `/api/health/ready`.

## Notifications (PRD §7b)

All notifications route via **Notification Hub** (no direct Resend/Twilio/Telegram integration). Onboarding via the `notification-hub-onboard` skill — its emitted output (registered tenant + rules + template IDs) is captured at `.agent/skills/notification-hub-onboard/output.md`. Every template below ships as a Liquid fixture in `test/fixtures/hub_templates/` and is exercised by template-binding tests over ≥2 distinct tenant snapshots:

| Template | Fixture | Trigger |
|----------|---------|---------|
| `vpi-risk-escalation-email` | `vpi_risk_escalation_email.liquid` | Any → HIGH |
| `vpi-risk-critical-email` | `vpi_risk_critical_email.liquid` | Any → CRITICAL |
| `vpi-risk-escalation-telegram` | `vpi_risk_escalation_telegram.liquid` | Any → HIGH |
| `vpi-risk-critical-telegram` | `vpi_risk_critical_telegram.liquid` | Any → CRITICAL |
| `vpi-risk-medium-email` | `vpi_risk_medium_email.liquid` | LOW → MEDIUM |
| `vpi-risk-improvement-digest` | `vpi_risk_improvement_digest.liquid` | Daily digest of improvements |
| `vpi-report-ready` | `vpi_report_ready.liquid` | Report status → `ready` |
| `vpi-ingestion-stale` | `vpi_ingestion_stale.liquid` | `ingestion_sources.last_successful_pull > 24h` (emitted by `Monitors::StaleIngestionMonitorJob`, hourly, idempotent within 6h) |
| `vpi-alias-review` | `vpi_alias_review.liquid` | Pending alias queue > 20 |

All templates bind to `DeliveryPayload` shape (§5.5) — frozen in `risk_alerts.delivery_payload` by `lib/alerts/capture_payload.rb` at alert creation, dispatched by `Alerts::HubDispatchJob`, never re-queried.

## Gotchas & Lessons Learned

> Gotchas catalog: `.agent/knowledge/gotchas/_index.md` — one file per gotcha, `YYYY-MM-DD-slug.md`. Do not append rows to this file; directory-per-kind only.

## Shared Foundation (MUST READ before any implementation)

> Foundation primitives live in `.agent/knowledge/foundation/` — one file per primitive. See `foundation/_index.md` for the catalog. The AI MUST read the relevant files in full before writing any new code that touches the surface they establish.
