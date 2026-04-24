# Foundation: Vendor Name Normalization

## What it establishes

Every vendor name that enters VPI — whether from an operator form, an invoice-recon payload, a contract event, or a RAG enrichment hit — passes through a single pure function that produces a deterministic fuzzy-match key. That key is stored in `vendors.normalized_name` and indexed as `(tenant_id, normalized_name)`. Without this, the resolver's rung-3 ("exact normalized_name match") and rung-4 ("Levenshtein ≤ 2") stages cannot exist.

The function is `Ingestion::NameNormalizer.call(raw)`; its behaviour is the contract.

## Files

- `lib/ingestion/name_normalizer.rb` — the pure function.
- `test/lib/ingestion/name_normalizer_test.rb` — the behavioural contract (15 cases).
- `app/models/vendor.rb` — `before_validation :populate_normalized_name` callback invokes the function whenever `canonical_name` changes.

## Pipeline (in order)

1. **Reject nil / blank** → `ArgumentError`. The caller (usually the resolver) decides whether to fall back to `source_ref`.
2. **Unicode NFKD** decompose + explicit eszett expansion (`ß` → `ss`, `ẞ` → `SS`) — NFKD alone does NOT decompose eszett.
3. **Strip combining diacritical marks** (U+0300..U+036F) → `Hauptstraße` → `hauptstrasse`, `café` → `cafe`.
4. **Downcase.**
5. **Normalize curly apostrophes** (U+2019 → U+0027): `O'Brien` → `o'brien`. Matches paste from Word documents.
6. **Replace anything not `[a-z0-9' ]` with a space** — keeps apostrophes in-token + word boundaries intact.
7. **Collapse runs of whitespace** (single space), strip leading/trailing whitespace.
8. **Tokenize** on single spaces.
9. **Strip trailing legal-suffix tokens**, repeatedly, until the tail token is NOT in the suffix list:
   - DE: `gmbh`, `ag`, `ug`, `ohg`, `kg`
   - FR: `sa`, `sarl`, `sas`
   - UK: `ltd`, `plc`, `limited`
   - US: `inc`, `llc`, `corp`, `corporation`, `co`, `llp`
   - Generic: `holdings`, `company`
10. **Rejoin** with single spaces. Empty result (all-suffix input like `"GmbH"`) is `""` — the caller decides how to handle it.

## Contract (non-negotiable)

- **Pure.** No I/O, no DB, no network, no Rails globals. Any call with the same input MUST return the same output regardless of the caller's context.
- **Idempotent.** `normalize(normalize(x)) == normalize(x)`.
- **Locale-insensitive.** The output is ASCII-ish lowercase with only letters, digits, apostrophes, and single spaces.
- **Only trailing suffixes are stripped.** `"including tech"` stays `"including tech"` — `inc` inside `including` is NOT stripped.
- **Stacked suffixes ARE stripped.** `"Foo Holdings LLC"` → `"foo"` (both `holdings` and `llc` are in the list).

## Decisions worth flagging

- **`Holdings` IS in the suffix list.** This is aggressive: it collapses `"RBS Holdings Ltd"` → `"rbs"`. The resolver's rung-2 (exact `tax_id` match, confidence 1.00) is the safety net against false-positive name collisions. If false-positive alias queues become a problem, revisit.
- **Apostrophes are preserved.** `"O'Brien"` → `"o'brien"`. Keeps Irish/UK family names as single tokens.
- **Eszett expansion** is explicit, not NFKD — because NFKD does not decompose `ß`.
- **Empty output is allowed** (all-suffix input). Upstream callers must handle `""` gracefully (e.g., the resolver falls back to `source_ref` when `name` is blank).

## When to read this

Before:
- Touching `lib/ingestion/name_normalizer.rb` for any reason.
- Adding a new vendor-name source that might bypass `Vendor`'s `before_validation` hook.
- Debugging a vendor-alias miss that a human would expect to hit.
- Expanding the legal suffix list (requires a RED test AND a sample audit of real vendor names — the collapse is aggressive).

## Cross-references

- Related modules: `lib/ingestion/vendor_resolver.rb` — consumer of the normalized key.
- Related patterns: `vendor-resolution-flow.md`.
- PRD: §5.2 Vendor Registry + Alias Resolver.
