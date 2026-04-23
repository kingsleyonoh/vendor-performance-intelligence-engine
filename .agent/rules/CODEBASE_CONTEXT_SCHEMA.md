# Vendor Performance Intelligence Engine — Database Schema Context

> Split from `CODEBASE_CONTEXT.md` to keep that file under 10K chars.
> Last updated: 2026-04-23

## Database Schema

| Table | Purpose | Key Fields |
|-------|---------|-----------|
| `tenants` | Tenant identity + API key + branding | `id`, `slug`, `api_key_hash`, `api_key_prefix`, `legal_name`, `full_legal_name`, `display_name`, `address`, `registration`, `contact`, `wordmark_url`, `brand_primary_hex`, `brand_accent_hex`, `locale`, `timezone` (§4.T columns bound by every template) |
| `vendors` | Canonical vendor directory per tenant | `tenant_id`, `canonical_name`, `normalized_name`, `tax_id`, `country_code`, `category`, `annual_spend_cents`, `currency`, `status` |
| `vendor_aliases` | Reconcile `(source_system, source_ref)` → `vendor_id` | `tenant_id`, `vendor_id`, `source_system`, `source_ref`, `confidence` |
| `signal_definitions` | System catalog of signal types (NOT tenant-scoped) | `code`, `category`, `source_system`, `direction`, `value_type`, `default_weight` |
| `vendor_signals` | Append-only time-series; partitioned monthly by `recorded_at` via `pg_partman` | `tenant_id`, `vendor_id`, `signal_code`, `value_numeric`, `value_boolean`, `context`, `window_start/end`, `recorded_at`, `status` |
| `vendor_scores` | Composite score snapshots (current + history) | `tenant_id`, `vendor_id`, `composite_score`, `band`, `trend`, `category_scores`, `top_contributors`, `window_days`, `scoring_rules_id`, `computed_at` |
| `scoring_rules` | Per-tenant weight config + band thresholds | `tenant_id`, `name`, `is_active`, `category_weights`, `signal_weight_overrides`, `band_thresholds`, `window_days`, `time_decay_half_life_days` |
| `risk_alerts` | Band-crossing alerts | `tenant_id`, `vendor_id`, `previous_band/new_band`, `direction`, `triggered_by_score`, `status`, `delivery_payload` (FROZEN at creation — §5.5), `hub_event_id`, `workflow_execution_id` |
| `vendor_reports` | Generated reports | `tenant_id`, `report_type`, `parameters`, `status`, `output_format`, `storage_path`, `inline_payload`, `tenant_snapshot` (FROZEN), `render_context` (FROZEN — §5.6) |
| `ingestion_sources` | Upstream system connection config | `tenant_id`, `source_system`, `is_enabled`, `connection_config`, `pull_mode`, `last_successful_pull` |
| `ingestion_runs` | Audit of ingestion batches | `tenant_id`, `ingestion_source_id`, `mode`, `status`, `signals_attempted/stored/rejected`, `retry_payload` (resumable cursor) |
| `audit_log` | Insert-only user/system action log | `tenant_id` (no FK — preserves after tenant deletion), `actor_type`, `actor_id`, `action`, `entity_type/id`, `before_state`, `after_state`, `occurred_at` |

### Partitioning
`vendor_signals` partitioned by range on `recorded_at`, one partition per month (`vendor_signals_2026_04`, etc.). `pg_partman` extension background job manages creation/drop. `PartitionManagerJob` runs daily at 01:00 UTC.

### Tenant Identity Columns (§4.T — bound by templates)
Every template (PDF scorecard, email alert, UI header, Hub event payload) renders against `TenantSnapshot` built from these columns on the `tenants` row:

| Column | Bound by |
|--------|---------|
| `legal_name` | PDF scorecard header, email footer |
| `full_legal_name` | PDF legal footer, re-tender recommendation doc |
| `display_name` | UI header, email greeting, Hub event payload `tenant.display_name` |
| `address` (JSONB) | PDF scorecard legal footer |
| `registration` (JSONB) | PDF legal footer, compliance-grade reports |
| `contact` (JSONB) | PDF scorecard footer, email footer |
| `wordmark_url` | PDF header, UI sidebar |
| `brand_primary_hex` | PDF accent, UI chrome, email accent |
| `brand_accent_hex` | PDF bars + band pills, UI CTAs, email CTA |
| `locale` | Report date/number formatting, email template selection |
| `timezone` | Report window labels, alert timestamps |

### Relationships summary

```
tenants ──┬─< vendors ──┬─< vendor_aliases
          │             └─< vendor_scores
          ├─< vendor_signals (partitioned; FK to vendors + signal_definitions)
          ├─< scoring_rules (one active per tenant)
          ├─< risk_alerts ──> vendor_scores (triggered_by_score)
          ├─< vendor_reports
          ├─< ingestion_sources ──< ingestion_runs
          └─< audit_log

signal_definitions (system catalog, not tenant-scoped)
```
