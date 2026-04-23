# {{PROJECT_NAME}} — Coding Standards: E2E Testing (Real Endpoints)

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

### E2E Test Architecture

**Backend E2E (API projects):**
1. Start the actual server: `npm run dev` or equivalent (NOT a test-mode in-process server)
2. Wait for ready signal (health check passes)
3. Hit real endpoints via HTTP (fetch, axios, or curl)
4. Assert on status codes, response bodies, headers
5. Stop the server after tests complete

**Frontend E2E (projects with UI):**
1. Start the dev server (backend + frontend)
2. Use Playwright to navigate pages and interact with the UI
3. Assert on visible elements, form submissions, navigation, error states
4. Capture screenshots on failure for debugging

**Both require local services running** (Docker PostgreSQL, Redis, etc.) — this aligns with the mock policy in `CODING_STANDARDS_TESTING_LIVE.md` ("Don't Mock What You Own").

### E2E Test File Structure
```
tests/e2e/
  api/                        ← Backend E2E tests
    auth.e2e.test.ts          ← Auth endpoint tests
    simulations.e2e.test.ts   ← Simulation endpoint tests
  ui/                         ← Frontend E2E tests (Playwright)
    login.spec.ts
    dashboard.spec.ts
  helpers/
    server.ts                 ← Start/stop server utilities
    seed.ts                   ← Test data seeding
```

### E2E vs Integration Tests
| Aspect | Integration (inject/supertest) | E2E (running server) |
|--------|-------------------------------|---------------------|
| Server | In-process, no real HTTP | Real HTTP, real port |
| Speed | Fast (~1ms per test) | Slower (~100ms+ per test) |
| What it catches | Handler logic, validation, DB | Middleware ordering, CORS, startup, ports |
| When to use | Every endpoint (RED/GREEN phase) | After REGRESSION passes (Step 7d) |
| Run command | `{{TEST_COMMAND}}` | `{{E2E_COMMAND}}` |

**Both are required.** Integration tests are your fast feedback loop (TDD). E2E tests are your deployment confidence check.

### E2E Test Cleanup
- Each E2E test must clean up its own data (delete created records, reset state)
- Use a dedicated test database or schema to avoid polluting dev data
- Kill the server process reliably in the `afterAll` hook — leaked processes block ports

### Bootstrap Setup for E2E
During `/bootstrap` Phase 0, a `[SETUP]` item should configure the E2E framework:
- Create `tests/e2e/` directory structure
- Install E2E dependencies (Playwright for frontend, or just fetch/node:test for API-only)
- Add `test:e2e` script to `package.json` (or equivalent)
- Add E2E config file if needed (`playwright.config.ts`)
- Verify the E2E command runs and exits cleanly (even with 0 tests)

### Honesty Check for E2E Skips
**E2E skip reasons are a high-fabrication surface** — sub-agents have historically tried to claim "E2E covered by integration tests" or "E2E deferred" to shortcut the running-server requirement. The canonical list of rejected skip patterns lives in `.agent/agents/yolo/yolo-honesty-checks.md` Section 2. When running a batch that touches endpoints, the ONLY valid skip reasons are:
- `SKIPPED_NO_ENDPOINTS` — the batch genuinely touched no endpoints (verify against `## Items Completed`)
- `SKIPPED_NO_SERVER` — the project has no server (pure library / CLI / static site)
- `E2E_NOT_CONFIGURED` — framework not installed yet; warning logged, not blocking

Any other skip reason (including "infrastructure required", "covered by integration tests", or `DEFERRED`) is rejected by YOLO master's Phase 3.2b as `E2E_DISHONEST_SKIP`.
