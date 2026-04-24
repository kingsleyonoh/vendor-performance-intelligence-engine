# Foundation: Signal Ingestion Pipeline

## What it establishes

`Ingestion::SignalIngester.call(payload:, tenant:)` — the single entry point every signal source (REST push, NATS consumer, Hub fanout subscriber, scheduled-pull adapter, manual UI entry) uses to turn a raw payload into a persisted `vendor_signals` row. It composes three earlier primitives (`SignalValidator`, `VendorResolver`, `VendorSignal.append!`) into a deterministic pipeline whose return shape is the contract every caller binds to — `{status, signal, vendor, rejection_reason}`.

The pipeline is the origin of Invariant 3 (signals are append-only facts): every successful call INSERTs exactly one row and never mutates one. It is also where the reject matrix (PRD §5.3) is enforced — the matrix is the list of reasons a signal can fail to become a row, and each reason maps one-to-one onto a `rejection_reason` sentinel consumable by downstream dashboards.

## Files

- `lib/ingestion/signal_ingester.rb` — the pipeline class.
- `lib/ingestion/signal_validator.rb` — dry-validation contract (upstream step 1).
- `lib/ingestion/vendor_resolver.rb` — resolver (upstream step 3).
- `app/models/vendor_signal.rb` — `VendorSignal.append!` (upstream step 5).
- `test/lib/ingestion/signal_ingester_test.rb` — 15-test contract covering happy path, dedup, reject matrix, terminated-vendor guard, tenant isolation, and hook wiring.

## Pipeline order (PRD §5.3 verbatim)

```
(payload, tenant)
   │
   ▼
[1] SignalValidator.call(payload)
      │ success? → continue
      │ failure → { status: :rejected,
      │             rejection_reason: <REASONS sentinel> }
      ▼
[2] find_dedup_signal: VendorSignal.where(tenant_id, source_system, source_event_id).first
      │ hit   → { status: :deduped, signal: existing }
      │ miss → continue
      ▼
[3] VendorResolver.resolve(tenant, source_system, source_ref, hints)
      │ → Vendor (new or existing) + VendorAlias
      ▼
[4] Terminated-vendor guard
      │ vendor.status == "terminated"
      │   → { status: :rejected,
      │       rejection_reason: "TERMINATED_VENDOR" }
      │   (post_insert_hook NOT fired)
      │ else continue
      ▼
[5] VendorSignal.append!(attrs)         ← transactional, idempotent
      │ returns new row OR existing on RecordNotUnique race
      ▼
[6] post_insert_hook.(signal)           ← fires OUTSIDE the transaction
      │ Phase 2 binds this to:
      │   ScoreRecomputeJob.perform_later(signal.vendor_id, signal.tenant_id)
      │ Phase 1 default: no-op proc
      ▼
{ status: :ingested, signal:, vendor:, rejection_reason: nil }
```

## Return shape (stable contract)

```ruby
{
  status: :ingested | :deduped | :rejected,
  signal: VendorSignal | nil,   # nil iff :rejected
  vendor: Vendor | nil,         # nil iff :rejected before resolution
  rejection_reason: String | nil
}
```

## Reject matrix (map → `vendor_signals.rejection_reason`)

| Reason | Stage | Trigger |
|--------|-------|---------|
| `MISSING_VENDOR_REF` | validator | vendor_ref is empty or lacks tax_id/normalized_name/source_system_ref |
| `UNKNOWN_SIGNAL_CODE` | validator | `signal_code` not in `signal_definitions` |
| `VALUE_OUT_OF_RANGE` | validator | rate outside [0,1], count/duration/money < 0 |
| `FUTURE_TIMESTAMP` | validator | `recorded_at` > now + 1h (clock-skew tolerance) |
| `STALE_TIMESTAMP` | validator | `recorded_at` < now − `MAX_SIGNAL_BACKFILL_DAYS` (default 365) |
| `WINDOW_INVERTED` | validator | `window_end` ≤ `window_start` |
| `TERMINATED_VENDOR` | ingester | resolver returned a vendor with `status='terminated'` |
| `VALIDATION_ERROR` | validator | default sentinel when no canonical sentinel matches |

## post_insert_hook (non-placeholder extension point)

The hook is a legitimate Phase-boundary pattern — NOT a TODO. The Phase 1 engine must run standalone (Invariant 2: standalone-first). Wiring the ScoreRecomputeJob in Phase 1 would force a job system to be running for every ingestion test; the hook defers that binding to Phase 2 where the job exists.

```ruby
# Phase 1 default (this batch):
Ingestion::SignalIngester.post_insert_hook = ->(_signal) { nil }

# Phase 2 initializer (future batch 011):
Ingestion::SignalIngester.post_insert_hook = ->(signal) do
  ScoreRecomputeJob.perform_later(signal.vendor_id, signal.tenant_id)
end
```

The hook fires ONLY on `:ingested`. It does NOT fire on `:deduped` (that row was already scored) or `:rejected` (no row to score).

## Tenant isolation

- Every query in steps 2, 3, 5 is scoped `WHERE tenant_id = tenant.id`.
- The resolver's transactional boundary guarantees the `VendorAlias` unique index `(tenant_id, source_system, source_ref)` contains the ingestion's tenant_id — same `source_ref` in two tenants creates two distinct vendors.
- A payload claiming to be Acme's cannot land in Globex's `vendor_signals` — enforced at three layers: the composite dedup index, the resolver, the insert.

## When to read this

Before:
- Implementing any new signal source (REST push controller, NATS consumer, Hub event subscriber, scheduled-pull adapter) — they all call `SignalIngester.call`.
- Adding a new field to the incoming payload shape — it must be declared in `SignalValidator` first.
- Adding a new rejection reason — it must be added to both `SignalValidator::REASONS` and the return value pathway.
- Wiring any post-ingest side effect (scoring, alerting, audit) — it goes on `post_insert_hook`, never inline in the ingester.

## Cross-references

- Related modules: `signal_validator.rb`, `vendor_resolver.rb`, `composite_scorer.rb` (reads the rows this produces).
- Related patterns: `vendor-resolution-flow.md`, `tenant-scoping-pattern.md`, `scoring-primitives.md`.
- PRD: §5.3 Signal Ingestion Pipeline, §4.5 vendor_signals, §14 `MAX_SIGNAL_BACKFILL_DAYS`, `INGESTION_BATCH_SIZE`.
- Invariants: #1 tenant-scoped, #2 standalone-first (hook), #3 append-only (VendorSignal.append!), #6 rules-driven (validator uses SignalDefinition).
