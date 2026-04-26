# Vendor Performance Intelligence Engine — Coding Standards: Live & Integration Testing

> Part 4 of 5. Also loaded: `CODING_STANDARDS.md` (core AI discipline), `CODING_STANDARDS_META.md` (skills, env, branching), `CODING_STANDARDS_TESTING.md` (core TDD), `CODING_STANDARDS_TESTING_E2E.md` (E2E via real HTTP), `CODING_STANDARDS_DOMAIN.md` (deploy/security)
> This file covers the mock policy, component testing, and in-process backend integration testing. E2E testing lives in `CODING_STANDARDS_TESTING_E2E.md`.

## Live Integration Testing (Mock Policy)

### The Rule: Don't Mock What You Own
If you control the service and can run it locally → test against the real thing.

### Service Fallback Hierarchy
When deciding how to test a service, follow this order:
1. **Local instance** (best) — Docker, CLI, emulator on your machine
2. **Cloud dev instance** (good) — dedicated test project / staging environment
3. **Mock** (last resort) — only when options 1 and 2 are impossible

### Test LIVE (Never Mock)
- Your database (local PostgreSQL, local Redis, local NATS (optional)) — validates schema, column names, constraints, query behavior
- Your own API endpoints — call the actual route, not a stub
- Your own server actions / business logic — test the real function
- File storage you control (local filesystem, local object storage)

### Mock ONLY These
- Third-party payment APIs (Stripe charges money)
- Email/SMS delivery (SendGrid/Twilio sends messages)
- Rate-limited external APIs you don't control
- Services with irreversible side effects
- Cloud-only services with no local emulator AND no dev tier

### No Services? No Problem
If the project has no external services (CLI tool, library, static site), this policy doesn't apply — just write standard unit tests.

### Why This Matters
A mock that returns `{ user_id: 1 }` will pass even when the real column is `userId`. A mock that returns success will pass even when the real constraint rejects your data. Mocks test your ASSUMPTIONS about the service. Live tests test REALITY.

### Common Mock Violations (DO NOT DO THESE)
- ❌ Mocking your database client to return fake rows — hit the real database
- ❌ Mocking your own API routes with `nock`/`msw` — call the real endpoint via test client
- ❌ Using an in-memory SQLite when production uses PostgreSQL — use the real PostgreSQL
- ❌ Mocking Redis/cache when it's running in Docker — connect to the real instance
- ✅ Mocking Stripe's charge API — you don't want to charge real money in tests
- ✅ Mocking SendGrid — you don't want to send real emails in tests
- ✅ Mocking an external API with rate limits — you don't control their uptime

### Test Cleanup
- Each test MUST clean up after itself (delete rows, reset state)
- Use transactions with rollback when possible for speed

## Backend API & Integration Testing (Rails)

> **VPI is Rails + Hotwire (server-rendered HTML + Turbo + Stimulus), not React.** Unit-level Hotwire behavior is validated indirectly; system UI tests are covered by Capybara + Playwright — see `CODING_STANDARDS_TESTING_E2E.md`. There is no React Testing Library equivalent in this project.
> **Note:** This is in-process integration testing via Rails `ActionDispatch::IntegrationTest`. For real-HTTP testing over the network, see `CODING_STANDARDS_TESTING_E2E.md`.

### When to Write API Integration Tests
- Every **API endpoint** (`/api/*`): test request → response cycle against the real Rails app via `ActionDispatch::IntegrationTest`
- Every **Sidekiq job**: test job execution against real DB + Redis; assert on state changes + re-enqueued jobs
- Every **NATS consumer**: publish a test message to a local NATS instance, assert the signal was stored
- Every **Rack middleware** (especially `lib/auth/api_key_authenticator.rb`): test request interception, auth guards, `Current.tenant` resolution

### What to Test
| Priority | Test This | Example |
|----------|-----------|---------|
| 1 | Request/response cycle | `post "/api/signals", headers: {"X-API-Key" => key}, params: {...}` → 201, returns accepted count |
| 2 | Input validation | Missing required field → 400 with dry-validation error path `details: [{path: "signal_code", issue: "..."}]` |
| 3 | Auth & authorization | No key → 401; wrong tenant's key → 404 (never 403 — never reveal existence); ActionPolicy role denial → 403 |
| 4 | Error handling | Invalid ID → 404; DB unique constraint → 409; unknown signal_code → 422 |
| 5 | Tenant isolation | Tenant A's key requesting Tenant B's vendor ID → 404, NOT 403 |
| 6 | Edge cases | Empty body, oversized payload, duplicate `source_event_id` (dedup silent skip) |

### API Testing Patterns (Rails)
- Use `ActionDispatch::IntegrationTest`. Hit endpoints with `post`, `get`, `patch`, `delete` directly against the app — this exercises the full Rack stack including the `api_key_authenticator` middleware.
- Test full request lifecycle — middleware, controller, Alba serializer, response
- Assert on status codes, parsed JSON body (`JSON.parse(response.body)`), AND headers where relevant (e.g., `X-RateLimit-Remaining` from Rack::Attack)
- Test pagination, filtering, and sorting with real DB rows loaded from fixtures

### Message/Event Consumer Testing
- For NATS: start a local NATS server (`docker compose up -d nats`), publish test messages, assert the consumer processes them correctly
- For Hub event ingress (`POST /api/signals/from-hub`): test HMAC verification + signal storage in the same request cycle
- Test error handling: malformed events (→ 422), duplicate events (→ deduped silently via `source_event_id`), consumer restart mid-batch

### File Naming & Location
- Controllers: `test/controllers/api/vendors_controller_test.rb`
- Jobs: `test/jobs/score_recompute_job_test.rb`
- Lib: `test/lib/scoring/composite_scorer_test.rb`
- Integration (cross-module): `test/integration/signal_ingestion_flow_test.rb`
- Shared helpers: `test/support/` (loaded automatically by `test/test_helper.rb`)
