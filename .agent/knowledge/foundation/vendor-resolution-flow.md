# Foundation: Vendor Resolution Flow

## What it establishes

Every inbound signal in VPI carries an upstream-service identifier: `(source_system, source_ref)` — e.g., Invoice Reconciliation's internal vendor row ID. That tuple MUST be translated into a canonical `vendors.id` within the caller's tenant before the signal can be scored. `Ingestion::VendorResolver` is the single entry point that does this translation, and it is what makes the append-only signal pipeline coherent — every signal pointing at the same vendor must resolve consistently even when upstream systems spell the vendor differently.

## Files

- `lib/ingestion/vendor_resolver.rb` — class method `resolve(tenant:, source_system:, source_ref:, name:, tax_id:, country_code:)`.
- `test/lib/ingestion/vendor_resolver_test.rb` — the 13-case behavioural contract.
- `app/models/vendor_alias.rb` + `app/models/vendor.rb` — the persistence surface.
- `lib/ingestion/name_normalizer.rb` — rung-3/4 fuzzy-match key producer.
- Gemfile entry `text ~> 1.3` — `Text::Levenshtein.distance` (stdlib Ruby has no edit-distance function).

## The ladder (PRD §5.2)

```
(tenant, source_system, source_ref, hints) →

  rung 1: (tenant_id, source_system, source_ref) alias exists?
            ├─ yes → return alias.vendor_id (idempotency; provisional flag audited)
            └─ no  → next

  rung 2: hints[:tax_id] present AND matches (tenant_id, tax_id)?
            ├─ yes → create alias at confidence 1.00, is_confirmed=true
            │        (AUTO_CONFIRM_EXACT_TAXID=true per §14)
            └─ no  → next

  rung 3: normalized(hints[:name]) matches (tenant_id, normalized_name)?
            ├─ yes → create alias at confidence 0.85, is_confirmed=false
            └─ no  → next

  rung 4: Levenshtein(normalized, v.normalized_name) ≤ AUTO_MATCH_FUZZY_THRESHOLD
          (default 2 per §14) against every non-terminated vendor in tenant?
            ├─ yes → create alias at confidence 0.70, is_confirmed=false
            └─ no  → next

  rung 5: create new Vendor (canonical_name = hints[:name] || source_ref,
           tax_id/country_code from hints)
           + alias at confidence 1.00, is_confirmed=true
```

## Return shape (stable contract)

```ruby
{
  vendor: Vendor,          # always present (fresh or pre-existing)
  alias: VendorAlias,      # always present (fresh or idempotent)
  confidence: Float,       # 0.70 | 0.85 | 1.00
  was_created: Boolean     # true iff rung 5 minted a new vendor row
}
```

## Transactional boundary

The whole ladder runs inside `ActiveRecord::Base.transaction`. Rung 5 creates a `Vendor` AND a `VendorAlias` in the same transaction — partial failure leaves neither row behind.

## Tenant isolation invariant

Every rung scopes its lookups to the caller's `tenant_id`. Same `source_ref` across two tenants creates two distinct vendors with two distinct alias rows — enforced by the unique index `(tenant_id, source_system, source_ref)` on `vendor_aliases`.

A tax_id match only hits when the `(tenant_id, tax_id)` row exists. Same tax_id across tenants is allowed at the DB level (unique index is `(tenant_id, tax_id) WHERE tax_id IS NOT NULL`) — this is by design: two tenants can legitimately have the same supplier.

## When to read this

Before:
- Implementing any new signal-ingestion path (REST, NATS, Hub fanout, REST pull).
- Modifying `Ingestion::VendorResolver` for any reason.
- Writing a test that depends on alias-hit-rate behaviour.
- Considering changes to `AUTO_MATCH_FUZZY_THRESHOLD` or `AUTO_CONFIRM_EXACT_TAXID`.

## Tunables (PRD §14)

- `AUTO_MATCH_FUZZY_THRESHOLD=2` — max Levenshtein distance for rung 4.
- `AUTO_CONFIRM_EXACT_TAXID=true` — whether rung 2 auto-confirms the alias (default yes; tax IDs are unforgeable enough).

## Cross-references

- Related modules: `lib/ingestion/signal_ingester.rb` (future — the primary caller).
- Related patterns: `name-normalization.md`, `tenant-scoping-pattern.md`.
- PRD: §5.2 Vendor Registry + Alias Resolver, §4.3 vendors, §4.4 vendor_aliases, §14 scoring tunables.
