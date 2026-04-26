# Vendor Performance Intelligence Engine — Architecture Rules (Rails 8)

> Split from `CODING_STANDARDS.md` to keep the core rules file under 10K chars. Read this file before writing any controller, job, lib/, or model code. Referenced from `CODING_STANDARDS.md` — Framework / Architecture Conventions.

## Dependency Hierarchy (PRD §9)

Enforced direction of imports; do not cross it:

```
controllers → lib/ingestion, lib/scoring, lib/ecosystem, lib/tenants, lib/alerts, lib/reports, models, policies, serializers
jobs        → lib/ingestion, lib/scoring, lib/ecosystem, lib/tenants, lib/alerts, lib/reports, models, lib/audit
lib/tenants → models (read-only)
lib/scoring → models (read-only)
lib/alerts  → lib/tenants, lib/scoring, models (read-only)
lib/ingestion → lib/scoring, lib/ecosystem, models
lib/ecosystem → (pure HTTP/NATS clients; no app code)
lib/reports → lib/tenants, lib/scoring, models (read-only)
lib/auth    → models
```

**Rule:** `app/` → `lib/` only. `lib/ecosystem/` NEVER imports from `app/` — it must remain a pure outbound-client layer so it can be reused from setup scripts, rake tasks, and future service extractions without pulling in Rails app state.

## Tenant Scoping (MANDATORY)

- Every data-bearing table has `tenant_id UUID NOT NULL` with an FK to `tenants`.
- Every query pattern is backed by a composite index on `(tenant_id, ...)`.
- Every query scoped via `Current.tenant` (Rails `CurrentAttributes` pattern, set by `lib/auth/api_key_authenticator.rb` middleware).
- `Current.tenant` is thread-local, auto-cleared at request end. Never read `tenant_id` off the request directly in controllers — go through `Current.tenant.id`.
- A curl with tenant A's API key MUST return 404 for tenant B's resources in every controller (integration-test-enforced — PRD §15).
- `audit_log` has `tenant_id` but no FK (preserves audit rows after tenant deletion). Auditor queries can read cross-tenant; app queries scope normally.

## Append-Only `vendor_signals` (Principle 3)

- `vendor_signals` is INSERT-only. No `UPDATE`, no `DELETE` in application code.
- Corrections insert a new row AND mark the previous row `status='superseded'` (the only mutation allowed — a status transition, never a value edit).
- Partitioned monthly by `recorded_at` via `pg_partman`. `PartitionManagerJob` handles rollover daily at 01:00 UTC; do not touch partitions manually.
- Scores are derived, never patched. If a score is wrong, fix the signals/rules and recompute — never hand-edit `vendor_scores`.
- Status transitions: `raw → normalized → scored`, or `raw → rejected`, or `normalized → superseded`. Any other transition is a bug.

## Snapshot Freezing (Config-Driven Surfaces — PRD §5.5 + §5.6)

Two critical snapshot shapes are captured ONCE and re-read forever. This is non-optional — it is what makes alert history and PDF reports legally defensible.

### Alert payloads — `risk_alerts.delivery_payload`

- Built by `lib/alerts/capture_payload.rb` (`Alerts::CapturePayload(vendor_score_id)`) at alert creation — the moment a `risk_alerts` row is inserted with `status='pending'`.
- The dispatcher (`HubDispatchJob`) reads from `delivery_payload` ONLY. It MUST NEVER re-query `tenants`, `vendors`, or `vendor_scores`.
- Retries (even days later) emit the frozen payload. If the tenant renames itself after the alert fires but before dispatch succeeds, the Hub receives the legal_name that was current at `created_at`, not the current one.

### Report context — `vendor_reports.tenant_snapshot` + `vendor_reports.render_context`

- Built by `lib/reports/capture_render_context.rb` (`Reports::CaptureRenderContext(vendor_reports.id)`) when `ReportGeneratorJob` transitions the row from `queued → generating`.
- Every re-render (operator clicks "Re-download PDF", admin exports a legal artifact, audit reprint 6 months later) binds to THIS, not a live DB read.
- Regenerating a PDF 30 days after its original `generated_at` MUST produce byte-identical tenant-identity sections (header, footer, legal block), even if the `tenants` row was modified in between.

### Strict-undefined rendering (both surfaces)

- ERB reports use `lib/reports/strict_fetch.rb` — a helper that raises `StrictUndefined` on missing paths.
- Hub templates register with `strict: true` (Liquid) / `strict: true` (Handlebars). Missing tokens MUST raise, never silently emit empty string.
- CI runs `Reports::TemplateLint` + Hub template fixture tests over every template with representative context fixtures using ≥2 distinct tenants. An unmapped token fails the build.

## Rails Conventions (VPI-specific bindings)

- **Authorization:** ActionPolicy. One policy per resource in `app/policies/`. Tenant scope is enforced at the policy layer, not in controllers.
- **Serialization:** Alba. One serializer per API-exposed resource in `app/serializers/`.
- **Validation (non-model inputs):** dry-validation 1.x. Use for ingestion payloads and any request contract that doesn't map 1:1 to an ActiveRecord model. ActiveRecord validations cover model-level constraints.
- **UI:** Hotwire (Turbo + Stimulus) + Tailwind CSS + ViewComponent (`app/components/`). ERB is for layouts only; everything rendered goes through a component.
- **Shared infra:** Faraday 2 singleton clients in `lib/ecosystem/` (initialized in `config/initializers/ecosystem_clients.rb`, held across requests, re-init on config reload, closed on SIGTERM).
- **Background jobs:** Sidekiq 7. Use `app/jobs/application_job.rb` as the base. Long-running subscribers (NATS) run as dedicated Sidekiq workers with SIGTERM handlers to flush ack state cleanly.
- **Tenant resolution:** `lib/auth/api_key_authenticator.rb` — Rack middleware. 12-char prefix lookup → constant-time SHA-256 compare → `Current.tenant`. Public-allowlist routes (`/api/tenants/register`, `/api/health/*`, `/api/signals/from-hub` HMAC-authenticated) bypass.
- **Audit:** every mutating action writes via `lib/audit/recorder.rb`. Entry points: controller action, job, rake task.

## Feature Flags (Standalone-First — PRD §2.2)

Every ecosystem integration is feature-flagged with `{SERVICE}_ENABLED=false` by default (`NOTIFICATION_HUB_ENABLED`, `WORKFLOW_ENGINE_ENABLED`, `WEBHOOK_ENGINE_ENABLED`, `INVOICE_RECON_ENABLED`, `CONTRACT_ENGINE_ENABLED`, `NATS_ENABLED`, `RECON_ENGINE_ENABLED`, `RAG_PLATFORM_ENABLED`). The core scoring engine must work with all flags off. Someone cloning the repo and running `docker compose up` gets a fully functional product without any ecosystem wiring.
