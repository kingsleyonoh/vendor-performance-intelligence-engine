# Foundation: Tenant Scoping Pattern

## What it establishes

Every query, controller, job, and background task in VPI reads and writes data **scoped to `Current.tenant`** (Rails `CurrentAttributes`, thread-local, auto-cleared at request end). This is PRD §2 Architecture Principle 1 and it is non-negotiable: a curl with Tenant A's API key returning any data belonging to Tenant B is a production incident.

## Files

- `app/models/current.rb` — `class Current < ActiveSupport::CurrentAttributes; attribute :tenant; end` (created on first use)
- `lib/auth/api_key_authenticator.rb` — Rack middleware that sets `Current.tenant` (future batch — Phase 1)
- `app/controllers/api/base_controller.rb` — raises `UNAUTHORIZED` if `Current.tenant` is nil at action time
- Every model with `tenant_id` — default scope / explicit `where(tenant_id: Current.tenant.id)` in every query

## Contract

### Setting `Current.tenant`

1. **ONLY `lib/auth/api_key_authenticator.rb` sets `Current.tenant`** in the request path. No controller, no ActionPolicy, no helper ever calls `Current.tenant = ...` on a live request.
2. **Background jobs MUST re-establish tenant context at `perform`** — Sidekiq does not carry `CurrentAttributes` across the fork boundary. Pattern: `def perform(tenant_id, ...); Current.set(tenant: Tenant.find(tenant_id)) { ... }; end`
3. **Rake tasks / scripts / test setup** may assign `Current.tenant = tenants(:acme_gmbh_de)` for isolated runs. Clear it in teardown.

### Reading tenant-scoped data

1. **NEVER read `request.headers["X-API-Key"]` or `params[:tenant_id]` directly** inside a controller action. Go through `Current.tenant.id`.
2. **Every data-bearing table has `tenant_id UUID NOT NULL` with FK to `tenants`** (except `signal_definitions` — system catalog, not tenant-scoped, and `audit_log` — `tenant_id` but no FK to survive tenant deletion).
3. **Every query pattern is backed by a composite index on `(tenant_id, …)`** — verified at migration review time.
4. **Model scopes MUST include `where(tenant_id: Current.tenant.id)`** — not `scope :for_tenant, ->(id) { ... }` that callers have to remember to apply.

### Cross-tenant = 404 (never 403, never 401)

When Tenant A authenticates correctly but requests a URL that names Tenant B's resource (vendor, signal, report, alert), the response is **404 NOT_FOUND** — not 403 FORBIDDEN, not 401 UNAUTHORIZED. Revealing that the resource exists-but-you-can't-see-it is a cross-tenant information leak.

Implementation: `Vendor.find(params[:id])` on `Vendor.where(tenant_id: Current.tenant.id)` raises `ActiveRecord::RecordNotFound`, which `BaseController`'s `rescue_from` renders as 404 `NOT_FOUND`. That single path covers both "vendor doesn't exist" and "vendor belongs to another tenant" uniformly.

### Audit log is cross-tenant by design

`audit_log` has `tenant_id` but no FK constraint. This lets auditor tooling query across tenants (for compliance reviews) while app code continues to scope normally. Operators CANNOT query other tenants' audit rows — that's enforced at the admin UI, not the DB.

## When to read this

Before:
- Creating a new migration (must include `tenant_id UUID NOT NULL` + composite index)
- Creating a new model (must default-scope or explicitly filter by `Current.tenant.id`)
- Creating a new controller action (must rely on `Current.tenant`, never re-read the API key)
- Creating a new Sidekiq job (must re-establish `Current.tenant` at `perform` entry)
- Writing a test for a multi-tenant feature (must load ≥2 tenants and assert A cannot see B's data)

## Cross-references

- Related modules: `lib/auth/` (future), every `app/models/`, every `app/controllers/api/`
- Related patterns: `auth-guard-pattern.md`
- PRD: §2 Architecture Principle 1 (Tenant Isolation), §4 Database Schema
- Architecture rules: `.claude/rules/architecture_rules.md` — "Tenant Scoping (MANDATORY)"
