# Foundation: Audit::Recorder — Single Entry Point for the Audit Trail

## What it establishes

Every mutating controller action and every mutating job calls `Audit::Recorder.record(...)`. One function, one signature, one place to change when the Phase 3 `audit_log` migration lands.

## Files

- `lib/audit/recorder.rb` — `record(actor:, action:, entity_type:, entity_id:, before_state: nil, after_state: nil, tenant_id: nil)` + `.enabled?` predicate
- `app/controllers/api/base_controller.rb` — `after_action :record_audit_trail, if: :mutating_action?` + `mutating_action?` predicate (matches `create`/`update`/`destroy`)
- `test/lib/audit/recorder_test.rb` — field shape, actor-serialization, `AUDIT_ENABLED` kill switch
- `test/controllers/api/base_controller_test.rb` — verifies the after_action fires on successful POST / stays silent on GET

## Contract

### Signature (stable across Phase 3 transition)

```ruby
Audit::Recorder.record(
  actor:,         # required — any object with :id, or a string like "system.cron"
  action:,        # required — "controller#action" or "job_class#method"
  entity_type:,   # required — model name as string ("Vendor", "ScoringRule")
  entity_id:,     # required — UUID string; or nil for aggregate actions (bulk-rescore)
  before_state:,  # optional — nil or JSON-safe hash; NEVER PII (pass IDs, not names)
  after_state:,   # optional — nil or JSON-safe hash; NEVER PII
  tenant_id:      # optional — defaults to Current.tenant&.id
)
```

### Output (Batch 005)

A single Rails.logger line tagged `[audit]` with a JSON body:

```
[audit] {"actor_type":"Tenant","actor_id":"...","action":"vendors#create","entity_type":"Vendor","entity_id":"...","tenant_id":"...","before_state":null,"after_state":{...},"request_id":"...","occurred_at":"2026-04-24T13:24:00+00:00"}
```

In production, Lograge ships this line to Axiom alongside the request's process_action line. The `request_id` field correlates the two.

### Output (Phase 3)

The body of `record` is swapped for an `INSERT INTO audit_log (...) VALUES (...)`. Callers DO NOT change — that is the whole point of this foundation.

### Rules

1. **Every mutating entry point calls `Audit::Recorder.record`.** Controller actions (create/update/destroy) do this automatically via the `Api::BaseController` after_action. Jobs + rake tasks call it explicitly inside the unit of work.
2. **`actor` is always required.** Pass `Current.tenant` from controllers, pass a string like `"system.cron"` from scheduled jobs, pass `Current.user` from UI controllers once tenant-scoped UI lands.
3. **Never pass raw PII in `before_state`/`after_state`.** Pass IDs and references; the audit log is a compliance surface, not a PII store.
4. **`AUDIT_ENABLED=false` (ENV) short-circuits the call.** Used only in test harnesses that need to assert on `refute_match(/\[audit\]/, ...)` or in explicit benchmarking. NEVER ship `AUDIT_ENABLED=false` to production.
5. **Audit failures must NEVER 500 the request.** The `record_audit_trail` after_action wraps the call in `rescue StandardError` and logs. The audit trail is safety-critical but not request-critical.

### Actor serialization

- An object responding to `:id` (e.g. `Tenant`, `User`) -> `actor_type = class.name`, `actor_id = id.to_s`.
- A bare string (e.g. `"system.cron"`) -> `actor_type = "String"`, `actor_id = the string itself`.

## When to read this

Before:
- Writing a new controller action that mutates state (create/update/destroy)
- Writing a new background job that mutates state
- Extending a rake task that mutates tenant / scoring / signal state
- Changing the `audit_log` column shape (Phase 3)
- Disabling auditing via env — do not. Always ask first.

## Cross-references

- Related foundation: `api-error-response-shape.md`, `tenant-scoping-pattern.md`, `session-auth-pattern.md`
- Related modules: `lib/audit/`, every `app/controllers/api/*_controller.rb`, every `app/jobs/*_job.rb`
- PRD: §4.12 (`audit_log` schema), §9 (`lib/audit/` ownership), §15 (compliance criteria)
