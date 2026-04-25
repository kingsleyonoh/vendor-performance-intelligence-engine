# Vendor Performance Intelligence Engine — Ecosystem & Operational Context

> Split from `CODEBASE_CONTEXT.md` to keep that file under the 10K rules-file cap. Extracted at Phase 2 close-out sync (2026-04-25). Covers external integrations, Hub notifications, deep module references, and observability tooling.

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
| Reports | `lib/reports/` — `base_generator`, `vendor_scorecard_generator` (PDF), `portfolio_risk_generator` (CSV/PDF), `retender_candidates_generator` (CSV), `trend_analysis_generator` (CSV/PDF), `capture_render_context`, `strict_fetch` + `app/jobs/reports/{report_generator,expired_report_reaper}_job.rb` + `app/controllers/{reports_controller,api/reports_controller}.rb` (LIVE — Phase 3 in progress) |
| Ingestion management UI/API | `app/controllers/api/ingestion/{sources,runs}_controller.rb` + `app/controllers/api/ingestion/sources/pull_now_controller.rb` + `app/controllers/settings/ingestion_sources_controller.rb` + `app/components/settings/` |
| Errors | `lib/errors/json_api_error.rb` (JSON:API-style error envelope) |
| Cache helpers | `lib/cache/{request_cache,scoring_config_cache,tenant_cache}.rb` |
| Audit | `lib/audit/recorder.rb` — DB insert into `audit_log_entries` (LIVE — Phase 3) with Lograge-tagged JSON fallback |
| Structured logging | `config/initializers/lograge.rb` + `request_id_instrumentation.rb` |
| Sidekiq config | `config/initializers/sidekiq.rb` + `Procfile.dev` + `config/schedule.yml` (sidekiq-cron schedules: `partition_manager` 01:00 UTC, `failed_alert_retry` every 30 min, `webhook_engine_signal_pull` every 10 min, `invoice_recon_backfill` / `contract_lifecycle_backfill` / `transaction_recon_backfill` every 15 min, `stale_ingestion_monitor` hourly, `expired_report_reaper` hourly @:05, `all_vendors_rescore` daily 02:00 UTC, `alias_auto_confirm` daily 04:00 UTC) |
| UI (dashboard, vendors list, vendor detail, alerts inbox, reports, aliases queue, settings, login) | `app/controllers/{dashboard,vendors,alerts,reports,vendor_aliases}_controller.rb` + `app/controllers/settings/{ingestion_sources,scoring,api_keys}_controller.rb` + `app/components/{auth,layouts,dashboard,vendors,alerts,reports,settings,scoring}/` |
| Architecture rules | `.agent/rules/architecture_rules.md` |

## Observability (PRD §10b)

| Concern | Tool |
|---------|------|
| Error tracking | Sentry (`SENTRY_DSN`) — gem installed (`sentry-ruby`, `sentry-rails`); DSN wiring pending Phase 3 |
| Logging | Lograge ACTIVE — JSON formatter, emits `request_id`, `tenant_id`, `user_id`, `params`, `exception` (`config/initializers/lograge.rb`). `lib/audit/recorder.rb` ALSO emits Lograge-tagged JSON for mutations as fallback when audit_log_entries table unavailable. Axiom token/dataset wiring pending Phase 3. |
| Uptime monitoring | BetterStack — probes `/api/health/ready` every 60s |
| APM | Prometheus + Grafana (self-hosted on VPS; scrape `/metrics`, Basic Auth via `METRICS_BASIC_AUTH_USER/PASS`) |
| Product analytics | PostHog (self-hosted). Events: `vendor_viewed`, `alert_acknowledged`, `scoring_rule_activated`, `report_generated`, `api_key_rotated` |

Health checks: `/api/health`, `/api/health/db`, `/api/health/redis`, `/api/health/ready`.
