# Vendor Performance Intelligence Engine — Module Context

> Split from `CODEBASE_CONTEXT.md` to keep that file under 10K chars.
> Last updated: 2026-04-23

> Per-module one-liners from PRD §5. Full module deep-dives live in `.agent/knowledge/modules/` — one file per module (created on first implementation touch).

## Modules

### 5.1 Tenant & Auth Middleware
`X-API-Key` header → first 12 chars (`api_key_prefix`) lookup → constant-time SHA-256 compare against `api_key_hash` → set `Current.tenant` (Rails `CurrentAttributes`, thread-local). Self-registration endpoint rate-limited 5/min/IP via Rack::Attack, gated by `SELF_REGISTRATION_ENABLED`. Code: `lib/auth/api_key_authenticator.rb` + `app/controllers/api/base_controller.rb`.

### 5.2 Vendor Registry + Alias Resolver
Canonical `vendors` directory + `vendor_aliases` reconciling `(source_system, source_ref)` tuples. Auto-match priority: exact tax_id (confidence 1.00) → exact normalized_name (0.85) → Levenshtein ≤ 2 (0.70) → new vendor (1.00). Operator confirms aliases with `confidence < 1.00` in a pending-review UI queue. Code: `lib/ingestion/vendor_resolver.rb` + `lib/ingestion/name_normalizer.rb`.

### 5.3 Signal Ingestion Pipeline
Receive (REST/NATS/Hub/pull/manual) → validate schema (dry-validation) → dedup on `(tenant_id, source_system, source_event_id)` → resolve vendor (via 5.2) → validate signal (range-check against `signal_definitions`) → insert `vendor_signals` (status='normalized') → enqueue `ScoreRecomputeJob`. Code: `lib/ingestion/signal_ingester.rb` + `lib/ingestion/signal_validator.rb`.

### 5.4 Composite Scorer
Given `vendor_id`: load active `scoring_rules` → query in-window `vendor_signals` → scale each signal to 0–100 contribution via `signal_scalers` → apply time decay (`weight_multiplier = 0.5^(age_days/half_life)`) → aggregate per category (weighted average) → apply `category_weights` → determine `band` + `trend` → select top-5 contributors → insert `vendor_scores` row → fire `risk_alerts` if band changed. Code: `lib/scoring/composite_scorer.rb` + `lib/scoring/signal_scalers.rb` + `lib/scoring/time_decay.rb` + `lib/scoring/band_classifier.rb`.

### 5.5 Risk Alert Router
On band crossing: suppression check (dedup window) → insert `risk_alerts` with `status='pending'` → build `DeliveryPayload` via `Alerts::CapturePayload(score_id)` ONCE (contains frozen `TenantSnapshot`) → enqueue `HubDispatchJob` → for HIGH/CRITICAL: enqueue `WorkflowEscalationJob`. Dispatcher reads ONLY from `delivery_payload` — never re-queries. Code: `lib/alerts/capture_payload.rb` + `app/jobs/alerts/hub_dispatch_job.rb` + `app/jobs/alerts/workflow_escalation_job.rb` + `app/jobs/alerts/failed_alert_retry_job.rb`.

### 5.6 Reporting Engine
Four report types: `vendor_scorecard` (PDF via WickedPDF), `portfolio_risk` (CSV/PDF), `retender_candidates` (CSV), `trend_analysis` (weekly aggregates). `ReportGeneratorJob` transitions `queued → generating` and calls `Reports::CaptureRenderContext(report_id)` ONCE — the full template-binding shape stored in `vendor_reports.render_context`. Every re-render binds to the stored snapshot (PDF re-downloads, audit reprints). Strict-undefined via `lib/reports/strict_fetch.rb`. Code: `lib/reports/*` + `app/jobs/report_generator_job.rb`.

### 5.7 RAG Platform Enrichment (feature-flagged)
Nightly `RagEnrichmentJob`: for each `vendor` with RAG-indexed documents, calls `GET /api/graph/entities?type=vendor&name=:normalized_name`. Result stored in `vendors.metadata.rag_enrichment`. Surfaced in vendor-detail UI as a "Background & Relationships" card. Never fails the engine on RAG downtime. Code: `lib/ecosystem/rag_platform_client.rb` + `app/jobs/rag_enrichment_job.rb`.

## Background Jobs (PRD §7)

| Job | Frequency |
|-----|-----------|
| `ScoreRecomputeJob` | Triggered per vendor signal |
| `AllVendorsRescoreJob` | Daily 02:00 UTC |
| `WebhookEngineSignalPullJob` | Every 10 min |
| `InvoiceReconBackfillJob` | Every 15 min |
| `ContractLifecycleBackfillJob` | Every 15 min |
| `TransactionReconBackfillJob` | Every 15 min (feature-flagged) |
| `ContractLifecycleNatsConsumerJob` | Long-running Sidekiq worker (NATS JetStream) |
| `HubDispatchJob` | Triggered per alert |
| `WorkflowEscalationJob` | Triggered per HIGH/CRITICAL alert |
| `FailedAlertRetryJob` | Every 30 min |
| `RagEnrichmentJob` | Daily 03:00 UTC (feature-flagged) |
| `ReportGeneratorJob` | Triggered per report |
| `ExpiredReportReaperJob` | Hourly |
| `PartitionManagerJob` | Daily 01:00 UTC |
| `AliasAutoConfirmJob` | Daily 04:00 UTC |

## Shared Utilities (MANDATORY — used by 2+ callers)

| Utility | Consumers |
|---------|-----------|
| `lib/ecosystem/hub_client.rb` | HubDispatchJob, Hub ingress verifier |
| `lib/ecosystem/workflow_client.rb` | WorkflowEscalationJob |
| `lib/ecosystem/webhook_engine_client.rb` | WebhookEngineSignalPullJob, setup scripts |
| `lib/ecosystem/invoice_recon_client.rb` | InvoiceReconBackfillJob, vendor_resolver |
| `lib/ecosystem/contract_engine_client.rb` | ContractLifecycleBackfillJob, vendor_resolver |
| `lib/ecosystem/recon_engine_client.rb` | TransactionReconBackfillJob, vendor_resolver |
| `lib/ecosystem/rag_platform_client.rb` | RagEnrichmentJob, vendor_resolver |
| `lib/ecosystem/nats_connection.rb` | ContractLifecycleNatsConsumerJob |
| `lib/scoring/composite_scorer.rb` | ScoreRecomputeJob, AllVendorsRescoreJob, preview endpoint |
| `lib/scoring/signal_scalers.rb` | composite_scorer, ingestion validator |
| `lib/ingestion/signal_ingester.rb` | All backfill jobs, NATS consumer, REST `/api/signals` |
| `lib/ingestion/vendor_resolver.rb` | signal_ingester, all backfill jobs |
| `lib/tenants/capture_snapshot.rb` | Alerts::CapturePayload, Reports::CaptureRenderContext, UI header |
| `lib/alerts/capture_payload.rb` | Band-crossing hook (ScoreRecomputeJob) |
| `lib/reports/capture_render_context.rb` | ReportGeneratorJob |
| `lib/reports/strict_fetch.rb` | All report ERB templates |
| `lib/audit/recorder.rb` | Every mutating controller + job |

Lifecycle rule: Faraday HTTP clients + NATS connection initialized in `config/initializers/ecosystem_clients.rb` at boot, held as singletons, re-initialized on config reload, gracefully closed on SIGTERM.
