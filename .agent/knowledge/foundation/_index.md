# Shared Foundation — Index

> **One file per foundation primitive.** This index is a human-readable catalog, rewritten by the AI whenever a sibling file is added, renamed, or removed. Never append to a single growing table — write a new sibling instead. See `.claude/rules/CODING_STANDARDS.md` — "Append-Only Knowledge Files Banned."

## Catalog

| File | Summary |
|------|---------|
| `api-error-response-shape.md` | JSON:API-style `{error:{code,message,details?}}` envelope + the 8 canonical codes + HTTP status mapping (PRD §8b). Bound by every controller, middleware, and 429 emitter. |
| `tenant-scoping-pattern.md` | `Current.tenant` (`ActiveSupport::CurrentAttributes`) + `(tenant_id, …)` composite indexes + cross-tenant → 404 (never 403). PRD §2 Architecture Principle 1 invariant. |
| `auth-guard-pattern.md` | Two-layer auth: `ApiKeyAuthenticator` Rack middleware (authentication, sets `Current.tenant`) + ActionPolicy (authorization, raises on deny). Stateless `Api::*` via `ActionController::API`. |
| `state-management-pattern.md` | UI multi-step flows: **server is the source of truth**, Turbo Frames for partial updates, ViewComponent for rendering, Stimulus for DOM behavior only. No client-side business state. |
| `cache-helpers.md` | Three-tier memoization convention: `Cache::RequestCache` (generic `vpi:<ns>:<key>` wrapper) -> `Cache::TenantCache` (api_key_prefix -> tenant_id, 60 s TTL) -> `Cache::ScoringConfigCache` (scoring_rules per tenant, 300 s TTL). PRD §10b. |
| `session-auth-pattern.md` | Two distinct auth surfaces: Rails 8 built-in session auth (email + password cookie) for UI (`/session`, `/passwords`); `X-API-Key` middleware for `/api/*`. Never cross-pollinate. PRD §5b, §8. |
| `audit-recorder.md` | `Audit::Recorder.record(...)` — single entry point every mutating controller + job calls. Emits tagged JSON log line in Batch 005; becomes an `audit_log` INSERT in Phase 3. PRD §4.12. |
| `tenant-snapshot-shape.md` | `Tenants::CaptureSnapshot.call(tenant_id)` — frozen `{id, slug, §4.T identity, snapshot_at}` hash that binds every template surface (PDF, Hub payload, email). Captured once at alert/report emission; never re-queried. PRD §4.T + §5.5 + §5.6. |
| `name-normalization.md` | `Ingestion::NameNormalizer.call(raw)` — pure function: raw vendor name → deterministic fuzzy-match key (lowercased, ASCII-ish, legal-suffix-stripped). Consumed by `Vendor` model (`before_validation`) + `Ingestion::VendorResolver`. PRD §5.2. |
| `vendor-resolution-flow.md` | `Ingestion::VendorResolver.resolve(...)` — the 5-rung ladder that translates `(source_system, source_ref, hints)` → canonical `vendor_id` (+ `vendor_alias` row for idempotency). Confidence levels 1.00 / 0.85 / 0.70. PRD §5.2. |

## What belongs here

Primitives imported by 3+ modules or that establish a project-wide contract. Examples: config loading, DB pool bootstrap, HTTP server bootstrap, auth middleware, shared error types, logging, feature flags, i18n.

## Mandatory reading rule

`CODING_STANDARDS.md` requires these files to be read **in full** before writing any new code that touches the surface they establish. The individual files in this directory replace the old flat `## Shared Foundation` table in `CODEBASE_CONTEXT.md`.

## How to add a new foundation primitive

1. Filename pattern: `category-slug.md` (e.g. `core-config-loading.md`, `db-pool-singleton.md`, `plugin-auth.md`).
2. Use the What it establishes / Files / When to read shape (mirror one of the existing files).
3. Add one row to the `## Catalog` table above.
4. Mirror the file into `.claude/knowledge/foundation/` (dual-mirror convention).

## Why directory-per-kind

Shared Foundation grows every time a new cross-cutting primitive lands. One row per primitive in a flat table becomes impossible to maintain once the project has 10+ primitives. Directory-per-kind scales — and each file is the right size to read "in full" without triggering context pressure.
