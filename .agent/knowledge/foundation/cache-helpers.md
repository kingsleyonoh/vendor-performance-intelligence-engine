# Foundation: Cache Helpers (Three-Tier Convention)

## What it establishes

A layered memoization convention that keeps hot-path lookups off Postgres without scattering `Rails.cache.fetch` calls across controllers, jobs, and `lib/` code. Three tiers:

1. **`Cache::RequestCache`** — generic namespaced wrapper around `Rails.cache`. Every key is built as `vpi:<namespace>:<key>` so operators can scan or flush specific concerns in Redis without nuking the whole keyspace.
2. **`Cache::TenantCache`** — `api_key_prefix -> tenant_id` lookups (60 s TTL). Used by `lib/auth/api_key_authenticator.rb` (Phase 1) so the middleware does not hit Postgres on every API request.
3. **`Cache::ScoringConfigCache`** — active `scoring_rules` per tenant (300 s TTL). Used by `lib/scoring/composite_scorer.rb` so bulk rescore batches don't refetch config on every vendor.

## Files

- `lib/cache/request_cache.rb` — generic wrapper (fetch / read / write / delete / build_key)
- `lib/cache/tenant_cache.rb` — `get` / `set(ttl:)` / `delete(api_key_prefix)`
- `lib/cache/scoring_config_cache.rb` — `fetch_for(tenant_id, &block)` / `invalidate(tenant_id)`
- `test/lib/cache/request_cache_test.rb` — namespace isolation, TTL, round-trip
- `test/lib/cache/tenant_cache_test.rb` — per-tenant isolation, expiration, cross-namespace no-leak
- `test/lib/cache/scoring_config_cache_test.rb` — per-tenant isolation, invalidate, TTL

## Contract

### Key shape

```
vpi:<namespace>:<key>
```

Examples:
- `vpi:tenant_by_prefix:abcd12345678` -> tenant UUID string
- `vpi:scoring_config:tenant:<uuid>` -> scoring rule hash

### Backing store

- **production**: Redis (same connection as Rack::Attack, see `config/initializers/rack_attack.rb`).
- **development**: `:memory_store` (`config/environments/development.rb`).
- **test**: `:null_store` by default — cache contract tests swap in `ActiveSupport::Cache::MemoryStore` in `setup` and restore in `teardown`. This keeps non-cache tests hermetic (no cross-test leakage) while making cache tests observable.

### TTL discipline

| Tier | TTL | Rationale |
|------|-----|-----------|
| `RequestCache` | caller-supplied | Generic wrapper; caller owns freshness. |
| `TenantCache` | 60 s | Balance: key rotation is visible within a minute without re-querying Postgres on every request. |
| `ScoringConfigCache` | 300 s | A scoring-rule change must be visible inside one dashboard refresh; bulk rescore jobs amortize load nicely. |

### Invalidation

Every tier supports explicit `delete` / `invalidate`. The writer of the underlying data is responsible for invalidating:

- Key rotation controller -> `Cache::TenantCache.delete(old_api_key_prefix)` + `.set(new_api_key_prefix, tenant.id)` in the same transaction.
- Scoring-rule mutations -> `Cache::ScoringConfigCache.invalidate(tenant_id)` after the write commits.

### Rules

1. **Never call `Rails.cache.fetch` directly from a controller, job, or `lib/`** — always go through a named tier helper so keys are namespaced consistently and TTL is centralized.
2. **The `tenant_id` in a cache key must be a UUID string**, never an integer column or a symbol. This prevents key collisions if an integer ID ever overlaps a UUID prefix.
3. **Never cache anything that could leak across tenants without the tenant_id embedded in the key.** Cross-tenant leakage via a shared cache is a PRD §2 invariant violation.
4. **Null-store in test mode applies to non-cache tests**; cache tests override to MemoryStore in setup. Do not switch the global test default.

## When to read this

Before:
- Adding any memoization / caching of an expensive lookup
- Wiring the `ApiKeyAuthenticator` middleware (Phase 1)
- Wiring the composite scorer's config lookup (Phase 1)
- Adding a new cached concern — create a new tier under `lib/cache/` rather than reaching for `Rails.cache.fetch` inline

## Cross-references

- Related patterns: `.agent/knowledge/patterns/` (TBD)
- Related modules: `lib/auth/` (Phase 1), `lib/scoring/` (Phase 1)
- PRD: §2 (Architecture Principles, tenant scoping), §10b (Performance & Observability)
