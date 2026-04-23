# Vendor Performance Intelligence Engine — Coding Standards: Testing (Core TDD)

> Part 2 of 4. Also loaded: `CODING_STANDARDS.md`, `CODING_STANDARDS_TESTING_LIVE.md`, `CODING_STANDARDS_DOMAIN.md`
> This file covers core TDD discipline. For mock policy, integration, component, and E2E testing → see `CODING_STANDARDS_TESTING_LIVE.md`.

## Testing Rules — Anti-Cheat (CRITICAL)

### Never Do These
- **NEVER modify a test to make it pass.** Fix the IMPLEMENTATION, not the test.
- **NEVER use `pass` or empty test bodies.**
- **NEVER hardcode return values** just to satisfy a test.
- **NEVER hardcode tenant-identity literals in templates/emails/invoices** just to make a template test pass. If `{{entity.X}}` doesn't resolve, extend the schema or escalate — never inline the literal. See `CODING_STANDARDS.md` — "No Silent Workarounds" and `CODING_STANDARDS_DOMAIN.md` — "Multi-Tenant Config-Driven Surfaces."
- **NEVER use broad exception handlers** to swallow errors that would make tests fail.
- **NEVER mock the thing being tested.** Only mock external dependencies.
- **NEVER skip or mark tests as expected failures** without explicit user approval.
- **NEVER weaken a test assertion** to make it pass.
- **NEVER delete a failing test.** Failing tests are bugs. Fix them.
- **NEVER run template/email/invoice tests against only one tenant fixture.** Single-tenant fixtures mask cross-tenant leakage. See "Multi-Tenant Fixtures Mandatory" below.

### TDD Sequence is Non-Negotiable
- Tests FIRST, then implementation. Never the reverse.
- You MUST create test files BEFORE creating implementation files.
- You MUST run tests and see RED (failures) before writing any implementation.
- You MUST show the RED PHASE EVIDENCE output (as defined in `implement-next.md` Step 5) before proceeding to Green Phase.
- The ONLY exception: `[SETUP]` items (scaffolding, config, infrastructure) where no testable behavior exists yet.
- If you catch yourself implementing without tests — STOP, delete the implementation, write the tests first.

### Always Do These
- **Test BEHAVIOR, not implementation.**
- **Test edge cases:** empty inputs, None, zero, negative, missing, duplicate.
- **Test sad paths:** API errors, timeouts, invalid data.
- **Assertions must be specific:** `assertEqual(result, expected)`, not `assertIsNotNone(result)`.

## Test Quality Checklist (Anti-False-Confidence)

Before moving from RED → GREEN, verify ALL applicable categories have tests:

| # | Category | What to Test |
|---|----------|-------------|
| 1 | Happy path | Does it work with valid, normal input? |
| 2 | Required fields | Does it reject nil/blank for required fields? |
| 3 | Uniqueness | Does it enforce unique constraints (incl. composite tenant-scoped indexes)? |
| 4 | Defaults | Do default values apply correctly when field is omitted? |
| 5 | FK relationships | Do foreign keys enforce CASCADE/RESTRICT correctly? |
| 6 | Tenant isolation | Can Tenant A see Tenant B's data? (MANDATORY — see Multi-Tenant Fixtures Mandatory below; includes PDF/email rendering via `tenant_snapshot` / `delivery_payload`) |
| 7 | Edge cases | Empty strings, zero, negative, very long strings, special chars, non-ASCII (UTF-8 tenant names) |
| 8 | Error paths | Faraday 5xx, timeouts, NATS disconnect, PostgreSQL down, malformed dry-validation input |
| 9 | String representation | Does `to_s` / `inspect` return something meaningful? |
| 10 | Meta options | Are ordering, indexes, and constraints working (`tenant_id`-first composite indexes)? |

**If a category applies and you skip it, you're cheating.** If RED phase shows fewer than 2 failures, add more tests — you're probably not testing enough.

### Performance Awareness
- Correctness tests alone don't catch latency regressions — a page can pass all tests while making 10× the necessary network calls
- When a single page/endpoint triggers 3+ backend operations, consider asserting call count or response time
- After every batch of 5+ features, do a compound load check: load real pages and verify total I/O matches expectations

### Multi-Tenant Fixtures Mandatory (CRITICAL — Catches Cross-Tenant Leakage)

If the project is multi-tenant (PRD §2 Architecture Principles mandates `tenant_id`), every test suite that touches tenant-scoped data MUST load **at least TWO distinct tenants** with different literal values for every tenant-identity column (legal_name, full_legal_name, display_name, address, registration, contact, wordmark).

**Why:** A template that hardcodes "Acme Corp LLC" passes every test when the fixture only loads Acme. It fails the moment Globex is onboarded. Two-tenant fixtures expose this at RED phase, not in production.

**Rules:**

1. **Fixtures file (`test/fixtures/tenants.yml`) MUST define ≥2 tenants** with intentionally-different identity values. VPI ships with `acme-gmbh-de` + `globex-inc-us` populated with distinct `legal_name`, `full_legal_name`, `display_name`, `address.country_code`, `locale` (`de-DE` vs `en-US`), `timezone` (`Europe/Berlin` vs `America/New_York`), `brand_primary_hex`, `brand_accent_hex`, `registration.*`, `contact.*`. Include edge cases: non-ASCII characters in one tenant's `display_name`, longer addresses, different jurisdictions.
2. **Template / email / PDF tests MUST parametrize over both tenants** (Minitest table-driven via `[tenants(:acme_gmbh_de), tenants(:globex_inc_us)].each do |tenant|`) and assert that rendering Tenant A's `TenantSnapshot` does NOT include any Tenant B literal value and vice versa.
3. **Cross-tenant leakage grep (runs in suite):** Add a test that reads the generated artifact (PDF text extraction, email body, Hub event payload JSON) and greps for EVERY literal identity value of the OTHER tenant. Any match fails the test with message `TENANT_IDENTITY_LEAK: field=X expected=A actual_included=B`.
4. **Tenant isolation test per module:** Category 6 in the Test Quality Checklist above is MANDATORY. Every query, every API response, every job run must be asserted to respect `tenant_id` scoping.

**This rule is non-optional for config-driven surfaces.** Skipping it means the template-hardcoding bug class (a surface hardcodes one tenant's literal identity, tests pass under a single-tenant fixture, leaks to production when a second tenant onboards) will re-occur project-by-project until tests catch it at RED.

## Edge Case Coverage Guide

### Models
- Every field from the spec → at least 1 test per constraint
- Every FK → test CASCADE behavior
- Every choice field → test all valid values + 1 invalid value

### Services (when applicable)
- Boundary values (min, max, zero, negative)
- Invalid input types
- Idempotency (running twice = same result)
- Mock external API failures

### Views/Pages (when applicable)
- Authenticated vs unauthenticated access
- Correct HTTP methods (GET/POST/PUT/DELETE)
- Response format validation
- Tenant scoping (if multi-tenant)

## Test Modularity Rules
1. **One test class per model/service** — never mix models in one class
2. **Max 300 lines per test file** — split if larger
3. **`setup` creates only what that class needs** — no global fixtures beyond the mandatory tenant fixtures
4. **Tests are independent** — no shared state, no ordering dependency (`parallelize(workers: :number_of_processors)` must pass)
5. **Any single test can run in isolation** — `bin/rails test test/models/vendor_test.rb:42` or `bin/rails test TEST=test/models/vendor_test.rb -n test_name`
6. **Test names describe business behavior** — not technical actions (`test "rejects signal with future recorded_at beyond 30 days"` not `test "raises ArgumentError"`)
7. **No test helpers longer than 10 lines** — extract to `test/support/` helper modules or a fixture factory

## Business-Context Testing
- Tests must reflect the BUSINESS PURPOSE described in the spec.
- Every test must answer: Does this protect data? Apply rules correctly? Handle failure? Match the spec?
- Test names must describe business behavior, not technical actions.

## Test Runner Commands (VPI — Minitest + Capybara + Playwright)

| Scope | Command |
|-------|---------|
| All unit + integration tests | `bin/rails test` |
| Single file | `bin/rails test test/models/vendor_test.rb` |
| Single test | `bin/rails test test/models/vendor_test.rb:42` |
| System (UI) tests via Capybara + Playwright | `bin/rails test:system` |
| Just one module's tests | `bin/rails test test/lib/scoring/` |
| Parallel (default on) | `bin/rails test -p` |

> **Integration, Component, E2E, and Mock Policy rules** → see `CODING_STANDARDS_TESTING_LIVE.md` (Part 3 of 4).
