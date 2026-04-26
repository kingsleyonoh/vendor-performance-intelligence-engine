# Foundation: RenderContext Shape (`Reports::CaptureRenderContext`)

## What it establishes

The single canonical shape of the FROZEN RenderContext hash stored on `vendor_reports.render_context` at the queued → generating transition (PRD §5.6). Every subsequent re-render of the report binds to the stored snapshot — the renderer NEVER re-queries `tenants`, `vendors`, `vendor_scores`, or `vendor_signals`. This is what makes audit reprints byte-identical 30 days after original generation, even if the underlying tenant/vendor rows have been mutated in between (PRD §15 #13).

This is the report-surface mirror of `Alerts::CapturePayload` (which freezes alert payloads in `risk_alerts.delivery_payload`). Both bind to `Tenants::CaptureSnapshot` for the tenant-identity block.

## Files

- `lib/reports/capture_render_context.rb` — `Reports::CaptureRenderContext.call(vendor_report:)`
- `test/lib/reports/capture_render_context_test.rb` — schema, deep-freeze, byte-identical re-render
- Downstream consumers (later Phase 3 batches):
  - `app/jobs/report_generator_job.rb` — calls `Reports::CaptureRenderContext` at the queued → generating transition; stores result in `vendor_reports.render_context` and `vendor_reports.tenant_snapshot`.
  - `lib/reports/vendor_scorecard_generator.rb`, `lib/reports/portfolio_risk_generator.rb`, etc. — bind ERB / CSV templates to the stored render_context, never to live data.
  - All ERB report templates use `lib/reports/strict_fetch.rb` to look up tokens against the stored render_context with strict-undefined behavior.

## Contract

### Top-level shape (locked — any change requires PRD §5.6 update first)

```ruby
{
  schema_version: "vpi.report.v1",
  generated_at:   "<ISO 8601 UTC>",
  tenant:         <Tenants::CaptureSnapshot output>,   # see tenant-snapshot-shape.md
  report: {
    id:                   UUID,
    type:                 String,    # one of REPORT_TYPES
    parameters:           Hash,      # stringify-keyed
    output_format:        String,    # "pdf" | "csv" | "json"
    requested_by_user_id: Integer | nil,
    generated_at:         String | nil,
    expires_at:           String | nil
  },
  data: <type-specific block — see below>,
  links: {
    download_url:  "<host>/api/reports/:id/download",
    view_url:      "<host>/reports/:id",
    legal_footer: {
      full_legal_name: String,
      address:         Hash,    # JSONB block from §4.T
      registration:    Hash,    # JSONB block from §4.T
      contact:         Hash     # JSONB block from §4.T
    }
  }
}.deep_freeze
```

### `data` block by report_type

| `report_type` | `data` shape |
|---------------|-------------|
| `vendor_scorecard` | `{ vendor:, latest_score:, score_history: [..12], signal_timeline: [..50], aliases: [..] }` |
| `portfolio_risk` | `{ vendor_count:, band_counts: {low:, medium:, high:, critical:}, vendors: [{vendor_id, canonical_name, band, composite_score}, ...] }` |
| `retender_candidates` | `{ candidates: [{vendor_id, canonical_name, band, composite_score, top_contributors}] }` (band IN [high, critical] only) |
| `trend_analysis` | `{ weekly_buckets: [{week_start, score_count, avg_composite, band_counts}], window_days: }` |

### Required preconditions

- `vendor_scorecard` requires a non-nil `vendor_id` on the report. Raises `ArgumentError` otherwise — there is no silent fall-through to an empty data block.
- `portfolio_risk`, `retender_candidates`, `trend_analysis` are tenant-scoped and ignore `vendor_id`.

### Immutability

The returned Hash is RECURSIVELY frozen (`deep_freeze`). Nested hashes, arrays, and strings are all frozen. Callers attempting to mutate any nested member raise `FrozenError`. This is stronger than the top-level-only freeze on `Tenants::CaptureSnapshot` because the RenderContext is durably stored as `vendor_reports.render_context` and read back potentially months later — JSON round-tripping at storage time also prevents drift.

### Unknown report

Raises `ArgumentError` if `vendor_report` is not a `VendorReport` instance.
Raises `ActiveRecord::RecordNotFound` if the underlying tenant_id does not resolve (delegated through `Tenants::CaptureSnapshot`).

## When to read this

Before:

- Writing any ERB/CSV report template that binds to render_context tokens
- Adding a new `report_type` (must extend the `data` block + tests + this doc)
- Changing the structure of any captured block (tenant, report, data, links)
- Hooking the `ReportGeneratorJob` into the queued → generating transition
- Touching `vendor_reports.render_context` storage / re-render flow

## Cross-references

- PRD §4.9 (`vendor_reports` schema), §5.6 (RenderContext shape — authoritative), §15 #13 (byte-identical re-render criterion)
- `.claude/rules/architecture_rules.md` — "Snapshot Freezing (Config-Driven Surfaces)"
- `.claude/rules/CODING_STANDARDS_DOMAIN.md` — "Multi-Tenant Config-Driven Surfaces"
- Related foundation docs: `tenant-snapshot-shape.md` (peer pattern for alerts), `audit-recorder.md`
