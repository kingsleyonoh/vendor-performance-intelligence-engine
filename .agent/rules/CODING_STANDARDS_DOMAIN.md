# Vendor Performance Intelligence Engine — Coding Standards: Domain & Production

> Part 4 of 4. Also loaded: `CODING_STANDARDS.md`, `CODING_STANDARDS_TESTING.md`, `CODING_STANDARDS_TESTING_LIVE.md`

## Deployment Flow (Dev → Production)

### Dev Branch Workflow
1. All implementation work happens on `dev` branch
2. Tests run against local services (local PostgreSQL, local Redis, local NATS (optional))
3. Each completed item → commit → push to `dev`
4. Run full test suite frequently

### When Ready to Deploy
1. Ensure ALL tests pass on `dev`
2. Merge `dev` → `main`
3. Push `main` → triggers deployment pipeline
4. Run migrations against production database
5. Verify deployment in production

### Emergency Hotfix Flow
- Branch from `main` → `hotfix/description`
- Fix + test → merge to BOTH `main` and `dev`
- Use `/hotfix` workflow for guidance

## Security Rules

### Secrets Management
- **NEVER hardcode secrets** — no API keys, passwords, tokens in source code OR deployment config files
- **docker-compose.prod.yml is git-tracked** — use `${VAR}` references, NEVER inline passwords. Create `.env` on the server for secrets.
- Use `.env` files locally (listed in `.gitignore`)
- Use environment variables in production
- If you accidentally commit a secret, **rotate it immediately** — secrets in git history are compromised even after deletion

### Input Validation
- Validate ALL user input at the boundary (API route, form handler)
- Use framework validators (Pydantic, Zod, Django Forms)
- Never trust client-side validation alone

### Authentication & Authorization
- Verify auth on EVERY protected endpoint
- Check permissions, not just authentication
- Log auth failures

### SQL & Data Safety
- Use parameterized queries or ORM methods — NEVER string concatenation for SQL
- Sanitize HTML output to prevent XSS
- Validate file upload types and sizes

### Multi-Tenant Config-Driven Surfaces (CRITICAL — Prevents Cross-Tenant Leakage)

If PRD §2 mandates `tenant_id`, these surfaces MUST NEVER contain hardcoded per-tenant literals: document templates (invoices, quotes, contracts, legal boilerplate), transactional emails, PDF/printable artifacts, admin UI copy naming "the operator", API responses echoing tenant identity.

**Banned:** legal entity names as HTML literals, registration/license/tax numbers as constants, addresses inlined into templates, contact email/phone as constants, logo/wordmark paths for one specific tenant, disclaimer text naming a specific regulator or entity.

**Required pattern — Template Context API:**

Every config-driven surface renders against an **immutable snapshot** captured at generation time (not a live lookup — re-renders MUST use the snapshot for legal/audit accuracy). Snapshot shape lives in PRD §5 (emitting module); backing columns in PRD §4 Tenant Identity Columns.

- Extend schema BEFORE writing the template. Never write a token whose backing field doesn't exist.
- Turn ON strict undefined handling: Handlebars `strict: true`, Jinja2 `StrictUndefined`, equivalent. Missing tokens MUST throw, not silently emit `""`.

**Test contract:**

- Template tests MUST load ≥2 tenants and assert Tenant A's render excludes any Tenant B literal. See `CODING_STANDARDS_TESTING.md` — Multi-Tenant Fixtures Mandatory.
- `validate-prd` and `security-audit` grep template directories for tenant literals. Matches = `TENANT_IDENTITY_LEAK`.

**If you hit a missing field:** apply "No Silent Workarounds" (`CODING_STANDARDS.md`). Escalate for schema extension. Do not hardcode.

**VPI-specific binding (Rails):** the project's `TenantSnapshot` shape is built by `lib/tenants/capture_snapshot.rb` (`Tenants::CaptureSnapshot(tenant_id)` — see PRD §4.T + §5.5 + §5.6). Every PDF scorecard renders against a frozen copy stored in `vendor_reports.render_context`; every Hub event payload renders against a frozen copy stored in `risk_alerts.delivery_payload`. The snapshot is captured ONCE (at `queued → generating` for reports, at alert creation for alerts) and never re-queried. Re-renders bind to the stored snapshot — never to a live `tenants` read. Backing columns: `legal_name`, `full_legal_name`, `display_name`, `address`, `registration`, `contact`, `wordmark_url`, `brand_primary_hex`, `brand_accent_hex`, `locale`, `timezone` (all on the `tenants` row per PRD §4.1).

## Environment Variables
- `.env` for local development (NEVER committed)
- `.env.example` for documenting required vars (committed, no real values)
- Production variables set via hosting platform UI/CLI
- NEVER log env var values

## Production-Readiness Rules (Before Merge to Main)

Before merging ANY feature to `main`:

1. **All tests pass** — `python -m pytest` / `npm test` / equivalent shows 0 failures
2. **No console.log / print debugging** — remove all debug output
3. **No TODO/FIXME/HACK** — resolve them or create tickets
4. **Error handling exists** — no unhandled exceptions in user flows
5. **Types are complete** — no `any` / `Any` types in TypeScript/Python typed code
6. **Migrations are committed** — all DB changes have migration files
7. **Environment variables documented** — new ones added to `.env.example`
8. **Linting passes** — code matches project style rules

## Code Organization Conventions

### Import Order
1. Standard library imports
2. Third-party package imports
3. Local/project imports
4. Blank line between each group

### Naming Conventions
- **Files:** `snake_case.py` / `kebab-case.ts` (follow project convention)
- **Classes:** `PascalCase`
- **Functions/Methods:** `snake_case` (Python) / `camelCase` (JS/TS)
- **Constants:** `UPPER_SNAKE_CASE`
- **Private:** Prefix with `_` (Python)

### Project Structure
- Follow the structure defined in `CODEBASE_CONTEXT.md`
- New modules go in the documented location for that type
- If unsure where something belongs, check `CODEBASE_CONTEXT.md` or ask

## Logging Standards
- Use structured logging (JSON format in production)
- Log levels: DEBUG (dev only), INFO (normal events), WARNING (recoverable), ERROR (failures), CRITICAL (system down)
- Include context: user_id, request_id, module name
- NEVER log sensitive data (passwords, tokens, PII)

## Error Response Standards
- Consistent error format across all endpoints
- Include: error code, human-readable message, timestamp
- Never leak stack traces to clients in production
- Log full error details server-side

## Server-Side Performance Rules

### Deduplicate Expensive Calls
If multiple functions on the same request path call the same expensive operation (auth check, config fetch, external API), extract it into a shared cached helper (e.g., request-scoped cache, singleton per request). Never let each function create its own call — N actions × M calls = latency multiplication.

### Parallel by Default
Independent operations (DB queries, API calls, file reads) MUST run concurrently (`Promise.all`, `asyncio.gather`, goroutines, etc.). Sequential execution is only for data-dependent chains where one result feeds the next.

### Wire It or Delete It (ENFORCED)
If you create a utility, middleware, handler, route, or service file, connect it to the framework entry point **in the same commit**. Unwired code creates false confidence — the feature "exists" but doesn't execute.

**This means:**
- New route handler → add it to the router in the same commit
- New middleware → add it to the middleware chain in the same commit
- New database query function → call it from a route/handler in the same commit
- New event consumer → register it with the event bus in the same commit
- New utility module → import and use it from the calling code in the same commit

If a function has no caller, a route has no handler, or a middleware is defined but not applied — it is dead code regardless of whether tests pass.

### Compound Load Audit
After implementing 5+ operations callable from a single entry point (page render, API endpoint, CLI command), audit total I/O calls. Features built incrementally work in isolation but compound into latency regressions that correctness tests never catch.

### Prefer Joins Over Multiple Queries
If the ORM/DB supports joins or eager loading, use them. N separate queries for N related tables is a sequential waterfall — one joined query is one round-trip. This includes any pattern where you fetch IDs from one table then loop to fetch details from another.

### Pin Compute to Data Region
Serverless functions must run in the same region as the database. Unmatched regions add 50-100ms per query. Set this in deployment config (vercel.json, fly.toml, etc.) during Phase 0 setup — not after performance problems surface.

## Code Structure Rules

### Thin Entry Points
Route handlers, server actions, CLI commands, and event handlers must stay thin — validate input, call a service/domain function, format the response. Extract business logic, side effects (notifications, logging, external calls), and data access into a separate layer. Entry points that mix multiple concerns become unmaintainable and untestable.

### Single State Mechanism Per Feature
Multi-step flows (wizards, forms, onboarding) must use ONE state management approach. Mixing persistence mechanisms (e.g., browser storage + in-memory cache + framework state + background sync) creates maintenance burden and race conditions. Pick one, stick with it.

### Modularity Awareness
Before adding code to any file, assess its current structure. Files should have a single clear responsibility. When a file's scope grows to cover multiple concerns, split by responsibility into separate modules — don't wait for a modularity audit. The project's limits (250 lines/file, 40 lines/function, 180 lines/class from `/check-modularity`) are guardrails, not targets.
