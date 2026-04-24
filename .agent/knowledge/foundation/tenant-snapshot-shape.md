# Foundation: TenantSnapshot Shape (`Tenants::CaptureSnapshot`)

## What it establishes

The single canonical shape of the `TenantSnapshot` hash that binds every config-driven surface in VPI: PDF vendor scorecards, Hub event payloads, email templates, legal artifacts. The shape is captured ONCE at the moment of emission (alert creation, report generation) and re-read forever — re-renders never re-query the `tenants` table.

This is the `[:id, :slug]` + every §4.T tenant-identity column + a `snapshot_at` timestamp, and nothing else. Adding a column to `tenants` does NOT automatically add it to the snapshot — every addition is a deliberate change to:

1. PRD §4.T table
2. `lib/tenants/capture_snapshot.rb` (this primitive)
3. Every template that might bind to it
4. Every fixture (`test/fixtures/tenants.yml`) — Multi-Tenant Fixtures Mandatory

## Files

- `lib/tenants/capture_snapshot.rb` — `Tenants::CaptureSnapshot.call(tenant_id)`
- `test/lib/tenants/capture_snapshot_test.rb`
- Downstream consumers (future batches):
  - `lib/alerts/capture_payload.rb` — stores the snapshot in `risk_alerts.delivery_payload` at alert creation (PRD §5.5)
  - `lib/reports/capture_render_context.rb` — stores the snapshot in `vendor_reports.tenant_snapshot` / `.render_context` when `ReportGeneratorJob` transitions queued → generating (PRD §5.6)

## Contract

### Shape (locked — any change requires PRD §4.T update first)

```ruby
{
  id:                UUID,     # from tenants.id
  slug:              String,   # from tenants.slug
  legal_name:        String,   # §4.T
  full_legal_name:   String,   # §4.T
  display_name:      String,   # §4.T
  address:           Hash,     # §4.T JSONB — {line1, line2, city, region, postal_code, country_code}
  registration:      Hash,     # §4.T JSONB — jurisdiction-keyed
  contact:           Hash,     # §4.T JSONB — {email, phone, support_url}
  wordmark_url:      String?,  # §4.T nullable — fallback wordmark when nil
  brand_primary_hex: String,   # §4.T — #RRGGBB
  brand_accent_hex:  String,   # §4.T — #RRGGBB
  locale:            String,   # §4.T — BCP47 (e.g. de-DE)
  timezone:          String,   # §4.T — IANA TZ (e.g. Europe/Berlin)
  snapshot_at:       String    # ISO 8601 UTC (e.g. 2026-04-24T15:03:21Z)
}.freeze
```

### Callable shape

- `Tenants::CaptureSnapshot.call(tenant_id)` — convenience class method; returns frozen Hash.
- `Tenants::CaptureSnapshot.new.call(tenant_id)` — instance form (preferred if you need subclassing / instrumentation).

### Must NOT leak

- `api_key_hash`, `api_key_prefix` — credentials, never serialized into any surface
- `settings`, `is_active`, `name`, `created_at`, `updated_at` — operational / audit metadata

The test `does NOT leak columns outside §4.T` enforces this exclusion.

### Immutability

The returned Hash is `.freeze`d at the top level. Callers cannot mutate it in place — but nested hashes (`address`, `registration`, `contact`) are NOT deep-frozen. Callers that need deep immutability should JSON-roundtrip before storing.

### Unknown tenant_id

Raises `ActiveRecord::RecordNotFound`. Callers are expected to let this bubble — an alert/report that cannot resolve its tenant is a catastrophic state, never silently fall through to an empty snapshot.

## When to read this

Before:

- Writing any template (ERB, Liquid, Handlebars) that binds to `{{tenant.*}}` tokens
- Writing any job that must freeze tenant identity for deferred dispatch
- Adding or removing a column from §4.T — this file and the PRD move in lockstep

## Cross-references

- PRD §4.T (authoritative column list), §5.5 (DeliveryPayload consumer), §5.6 (RenderContext consumer)
- `.claude/rules/architecture_rules.md` — "Snapshot Freezing (Config-Driven Surfaces)"
- `.claude/rules/CODING_STANDARDS_TESTING.md` — "Multi-Tenant Fixtures Mandatory"
- Related foundation docs: `tenant-scoping-pattern.md`, `auth-guard-pattern.md`
