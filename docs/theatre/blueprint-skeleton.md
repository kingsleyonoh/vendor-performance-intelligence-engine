# Blueprint Skeleton — vendor-performance-intelligence-engine

> **STATUS: SKELETON.** Not publishable. Hand this to a dedicated `architect-theatre` invocation in a follow-up session. See `README.md` in this directory for context.

## Target output

`C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\blueprint\vendor-performance-intelligence-engine-blueprint.md`

## Audience

CTO / Architect — reads the spec sheet to evaluate the system topology and judge the engineering decisions.

## Intended pillar

`proprietary` — moat strictness HIGH. Show system topology, decision rationale, outcomes. Hide acquisition mechanics for any specific tenant's signal weights or threshold tuning.

## Suggested decision-log seeds

The richest source is the build journal at `docs/build-journal/_index.md` (32 batches) plus `.claude/knowledge/foundation/_index.md`. Strong candidate decisions to defend:

- **Append-only `vendor_signals` with native Postgres range partitioning** vs a mutable signal table with row-level versioning. Justification: deterministic recompute (same signals + same rules → identical scores), trivial audit trail, native partition pruning on `recorded_at`. Trade-off: corrections require an INSERT + status flip rather than an UPDATE.
- **Frozen `DeliveryPayload` and `RenderContext` snapshots** vs live tenant lookups at dispatch/render time. Justification: re-rendering a PDF 30 days later must produce byte-identical legal sections; a tenant rename mid-retry must not poison the alert. Trade-off: storage cost (one JSONB blob per alert + one per report) and a strict-undefined ERB layer that fails CI on missing tokens.
- **Rules-driven scoring with per-tenant config** vs gradient-boosted classifier. Justification: procurement officers don't buy black boxes they have to defend to a CFO. Every score decomposes into the top 5 contributors. Trade-off: can't capture interactions between signals — Phase 4 ML supplements, doesn't replace.
- **Standalone-first with feature-flagged ecosystem adapters** vs ecosystem-required core. Justification: someone who clones the repo and runs `docker compose up` should get a fully functional product. Trade-off: every adapter needs both an integration path AND a manual REST path, doubling the surface area of the ingestion pipeline.
- **Rack middleware for `X-API-Key`** vs Devise/Rodauth API token plugin. Justification: 12-char prefix lookup → constant-time SHA-256 compare → `Current.tenant` is ~30 lines of explicit code. The plugin layer would add three dependencies and obscure the tenant-resolution path. Trade-off: we own the cache invalidation logic (`Cache::TenantCache`).

## Suggested system topology diagram

12-node Mermaid `graph TB`. The README's diagram is a starting point but the Blueprint version should annotate each ingress arrow with the feature flag (`NOTIFICATION_HUB_ENABLED`, `WEBHOOK_ENGINE_ENABLED`, etc.) and call out the frozen-snapshot boxes (`risk_alerts.delivery_payload`, `vendor_reports.render_context`) as distinct from the live-DB boxes.

## Numbers to verify against codebase before publishing

- 12 schema tables (PRD §4)
- 15 background jobs (PRD §7)
- 39 API endpoints (PRD §8b)
- 9 Hub Liquid templates (`test/fixtures/hub_templates/*.liquid`)
- 947 tests / 2909 assertions (this batch's regression run — replace if changed at publish time)
- 4 report types (vendor_scorecard, portfolio_risk, retender_candidates, trend_analysis)
- 5 ecosystem outbound clients + 1 inbound HMAC ingress

## Cross-collision flags

Read `kingsleyonoh.com/content/blueprint/` opening 20 lines of every file before publishing. Avoid:
- Reusing the "X tables, Y jobs, Z endpoints" opening if another blueprint already opens that way
- Reusing specific numbers from the Invoice Reconciliation or Contract Lifecycle blueprints (sibling ecosystem projects)
