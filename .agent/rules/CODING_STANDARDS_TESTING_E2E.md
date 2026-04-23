# Vendor Performance Intelligence Engine — Coding Standards: E2E Testing (Real Endpoints)

> Part 5 of 5. Also loaded: `CODING_STANDARDS.md` (core AI discipline), `CODING_STANDARDS_META.md` (skills, env, branching), `CODING_STANDARDS_TESTING.md` (core TDD), `CODING_STANDARDS_TESTING_LIVE.md` (mock policy + component + in-process backend integration), `CODING_STANDARDS_DOMAIN.md` (deploy/security)
> This file covers end-to-end testing that hits a running server via real HTTP. In-process testing (supertest, inject, test clients) lives in `CODING_STANDARDS_TESTING_LIVE.md`.

## E2E Testing (Real Endpoints)

> E2E tests hit a RUNNING server over HTTP — not in-process test clients like `inject()` or `supertest`.
> The point is testing the deployed stack: server startup, middleware chain, database, cache, and response serialization.
> These catch issues that unit/integration tests miss: port binding, CORS headers, middleware ordering, connection pool behavior under load.

### When E2E is Required
- **Any batch that creates or modifies an API endpoint** → E2E MUST hit the running server
- **Any batch that creates or modifies a page/component with user interaction** → E2E MUST include a browser test
- **Pure utility/library/config batches with no endpoints** → E2E not required (skip with note)
- **`[SETUP]` items** → E2E not required unless the setup itself starts a server

### E2E Test Architecture (VPI — Rails + Hotwire)

**Backend E2E (shell-level against a running Puma):**
1. Boot the actual Rails server: `bin/rails server -p 3001 -e test` (or `bin/dev` — NOT a test-mode in-process server like `ActionDispatch::IntegrationTest`)
2. Wait for `/api/health/ready` to return 200
3. Hit real endpoints via `curl` / `Net::HTTP` / Faraday from the test process — no test client shortcuts
4. Assert on status codes, parsed JSON response bodies, headers (CORS, `X-RateLimit-Remaining`, `Location`)
5. Shut down the server cleanly (`Process.kill('TERM', pid); Process.wait(pid)`) in `teardown`

**UI E2E (Hotwire pages via Capybara + Playwright):**
1. Rails `ApplicationSystemTestCase` configured with `driven_by :playwright` (via the `capybara-playwright-driver` gem)
2. `bin/rails test:system` boots Puma automatically at a random port
3. Use Capybara DSL (`visit`, `click_on`, `fill_in`, `assert_selector`) to drive Turbo + Stimulus pages
4. Assert on visible elements, Turbo-frame updates, form submissions, navigation, flash messages, band-color pill presence
5. Playwright captures screenshots on failure (`screenshots/failures/`) automatically

**Both require local services running** — `docker compose up -d postgres redis` (and optionally `nats`). This aligns with the mock policy in `CODING_STANDARDS_TESTING_LIVE.md` ("Don't Mock What You Own").

### E2E Test File Structure (VPI)
```
test/
  system/                     ← Capybara + Playwright UI tests (run via bin/rails test:system)
    dashboard_test.rb
    vendor_detail_test.rb
    alerts_inbox_test.rb
    scoring_rules_test.rb
  e2e_api/                    ← Shell-level API E2E tests against running Puma (run via a custom rake task `rake test:e2e`)
    signals_flow_test.rb      ← POST /api/signals → score recompute → band change → alert dispatch
    tenant_isolation_test.rb  ← cross-tenant 404 assertions
    health_test.rb            ← /api/health/* uptime probes
  support/
    server_boot.rb            ← start/stop Puma helper for e2e_api
    vcr_cassettes/            ← frozen ecosystem responses
```

### E2E vs Integration Tests
| Aspect | Integration (`ActionDispatch::IntegrationTest`) | E2E (running Puma / Capybara+Playwright) |
|--------|-------------------------------|---------------------|
| Server | In-process, no real HTTP | Real HTTP, real port |
| Speed | Fast (~1ms per test) | Slower (~100ms+ per test; UI 500ms+) |
| What it catches | Handler logic, validation, DB, ActionPolicy | Rack middleware ordering, CORS, startup, Traefik routing, Turbo + Stimulus wiring |
| When to use | Every endpoint (RED/GREEN phase) | After REGRESSION passes (Step 7d) |
| Run command | `bin/rails test` | `bin/rails test:system` (UI) and `rake test:e2e` (shell-level API) |

**Both are required.** Integration tests are your fast feedback loop (TDD). E2E tests are your deployment confidence check.

### E2E Test Cleanup
- Each E2E test must clean up its own data (delete created records, reset state)
- Use a dedicated test database or schema to avoid polluting dev data
- Kill the server process reliably in the `afterAll` hook — leaked processes block ports

### Bootstrap Setup for E2E
During `/bootstrap` Phase 0, a `[SETUP]` item should configure the E2E framework:
- Create `test/system/` and `test/e2e_api/` directory structure
- Install E2E dependencies: `capybara`, `capybara-playwright-driver`, and `playwright-ruby-client` in the Gemfile; run `bundle exec playwright install chromium`
- Configure `ApplicationSystemTestCase` with `driven_by :playwright`
- Add a `test:e2e` rake task in `lib/tasks/test.rake` that boots Puma and runs `test/e2e_api/*_test.rb`
- Verify `bin/rails test:system` and `bin/rake test:e2e` run and exit cleanly (even with 0 tests)

### Honesty Check for E2E Skips
**E2E skip reasons are a high-fabrication surface** — sub-agents have historically tried to claim "E2E covered by integration tests" or "E2E deferred" to shortcut the running-server requirement. The canonical list of rejected skip patterns lives in `.agent/agents/yolo/yolo-honesty-checks.md` Section 2. When running a batch that touches endpoints, the ONLY valid skip reasons are:
- `SKIPPED_NO_ENDPOINTS` — the batch genuinely touched no endpoints (verify against `## Items Completed`)
- `SKIPPED_NO_SERVER` — the project has no server (pure library / CLI / static site)
- `E2E_NOT_CONFIGURED` — framework not installed yet; warning logged, not blocking

Any other skip reason (including "infrastructure required", "covered by integration tests", or `DEFERRED`) is rejected by YOLO master's Phase 3.2b as `E2E_DISHONEST_SKIP`.
