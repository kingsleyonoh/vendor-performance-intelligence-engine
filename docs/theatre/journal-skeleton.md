# Journal Skeleton — vendor-performance-intelligence-engine

> **STATUS: SKELETON.** Not publishable. See `README.md` in this directory for context.

## Target output

`C:\Users\harri\OneDrive\Documents\SAAS DEV\klevar.ai\kingsleyonoh.com\content\journal\vendor-performance-intelligence-engine-<topic-slug>.md`

## Audience

Senior engineer — wants to read a 2,000-word essay defending one specific architectural decision with the failure stories that informed it.

## Candidate topics (pick ONE — Journal essays are deep, not broad)

### Topic A — "Why the alert dispatcher reads from a frozen JSONB blob, not the database"

The defensive arc: a tenant renames itself (legal_name change, address change) between alert insert and Hub delivery. Naïve dispatchers re-query the tenants table, send the new name, and the audit log shows an alert that was "delivered" with identity that didn't exist when the alert fired. The PRD §5.5 contract is that alerts are legal documents — the identity in the payload IS the identity at the moment of band crossing.

The implementation: `lib/alerts/capture_payload.rb` builds a `DeliveryPayload` Hash containing the entire `TenantSnapshot` (11 §4.T columns) at insert time. The job consumes ONLY from `risk_alerts.delivery_payload`. Tested by `test/integration/alert_snapshot_freeze_test.rb` which renames the tenant between insert and retry.

The hard part: stopping the dispatcher from "helpfully" re-reading the tenants row to "make sure the data is fresh." That's the failure mode every engineer reaches for. The discipline is to write code that LOOKS LIKE it should re-read but doesn't.

### Topic B — "Strict-undefined ERB and the cost of silent string coercion"

The opening: Rails ERB happily renders `<%= h(tenant.legal_nme) %>` as the empty string. A typo in a template that should display a German GmbH's full legal name silently produces a PDF with a blank header. Procurement officers send the PDF to the audit committee. Audit committee asks why the legal entity is missing.

The solution: `lib/reports/strict_fetch.rb` — a path helper that raises `Reports::StrictFetch::FetchError` on any missing key. Every ERB template uses `f("tenant.legal_name")` instead of `tenant.legal_name`. CI runs `test/integration/report_template_lint_test.rb` over every template against two distinct tenant fixtures with strict-undefined ON. Any missing token fails the build.

The hard part: deciding whether to fail-loud at render time (and risk a 500 in production) or fail-loud at test time (and risk a missed token if the test fixture doesn't exercise the code path). We chose test-time enforcement, with the production-time error being the loud-then-recoverable kind: the report generator catches `FetchError`, marks the report `failed`, and the operator can re-render after the template fix ships.

### Topic C — "The five-rung vendor resolution ladder"

`Ingestion::VendorResolver` has five passes: cached alias hit → exact tax_id match → exact normalized_name match → Levenshtein ≤ 2 → new vendor. Each rung is a different confidence level (1.00 / 1.00 / 0.85 / 0.70 / 1.00) with different auto-confirm semantics.

The hard part: deciding what "exact match" means when one source spells the vendor "ACME GmbH" and another spells it "Acme Manufacturing GmbH" and a third has the trade name "Acme Mfg." Levenshtein with German legal-suffix stripping (`GmbH`, `KG`, `AG`) gets it right ~92% of the time; the remaining 8% surface in the operator alias-review queue. Auto-confirm-on-tax-id-match is the safety valve.

## Recommended topic: A or B

Topic A connects to the most distinctive architectural commitment in the entire project (snapshot freezing for legal defensibility). Topic B is more universal and might generate broader engagement.

## Anti-patterns to avoid

- Don't use the inversion pattern ("The X wasn't Y. It was Z.") — it's already overrepresented site-wide (cap = 2). Check `references/banned_list.md` and the spillover index.
- Don't open with "The obvious fix was..." — also overrepresented.
- Don't enumerate the 12 schema tables. That's Blueprint material, not Journal material.

## Numbers to verify against codebase before publishing

- 11 §4.T identity columns on the `tenants` row (counted in PRD §4.T)
- `MAX_ALERT_DISPATCH_ATTEMPTS=10` (the retry cap)
- `AUTO_MATCH_FUZZY_THRESHOLD=2` (Levenshtein distance)
- 9 Hub Liquid templates, all binding to the same `DeliveryPayload` shape
- Half-life default: 45 days (`DEFAULT_TIME_DECAY_HALF_LIFE_DAYS`)
