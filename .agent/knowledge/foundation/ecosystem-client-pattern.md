# Foundation: Ecosystem Client Pattern (Faraday + Retry + Circuit Breaker)

## What it establishes

The single canonical shape of every outbound HTTP client to an
ecosystem service (Notification Hub, Workflow Engine, Webhook
Engine, Invoice Recon, Contract Lifecycle, Transaction Recon, RAG
Platform). Hub client (`Ecosystem::HubClient`) is the reference
implementation; subsequent batches add sibling clients that mirror
the same lifecycle + retry + circuit-breaker contract.

## Files

- `lib/ecosystem/circuit_breaker.rb` — `Ecosystem::CircuitBreaker` (pure Ruby; thread-safe via `Concurrent::AtomicReference`)
- `lib/ecosystem/hub_client.rb` — `Ecosystem::HubClient` (Faraday 2 client to Notification Hub)
- `config/initializers/ecosystem_clients.rb` — singleton wiring + SIGTERM hook
- `test/lib/ecosystem/circuit_breaker_test.rb`
- `test/lib/ecosystem/hub_client_test.rb`

## Contract

### Required surface for every adapter

Every `lib/ecosystem/<service>_client.rb` MUST:

1. **Be Faraday 2-based** with the canonical middleware stack:
   - `request :json` (encode bodies as JSON)
   - `response :logger` with API-key filtering (never log secrets)
   - `request :retry` with `max: 3`, exponential backoff to 30s, retry on `[429, 502, 503, 504]` + network errors (`ConnectionFailed`, `TimeoutError`, `Errno::ETIMEDOUT/ECONNRESET/ECONNREFUSED`)
   - `open_timeout: 5`, `timeout: 30`
   - Headers: `X-API-Key`, `Content-Type: application/json`, `Accept: application/json`, `User-Agent: vpi/<version> (faraday)`
2. **Hold a per-adapter `CircuitBreaker`** — 5 failures within 60s → OPEN; 60s cooldown → HALF_OPEN; success → CLOSED.
3. **Be initialized as a singleton in `config/initializers/ecosystem_clients.rb`** at boot, held across requests, re-init on config reload, gracefully closed at SIGTERM (`at_exit { instance.close rescue nil }`).
4. **Honor the `<SERVICE>_ENABLED` flag** (PRD §2.2 standalone-first invariant) — when disabled, return `{status: :skipped, reason: "<service> disabled"}` without making any network call.

### Public method shape (per call)

Each public verb on the client returns one of three terminal shapes
(or raises one of two transient errors):

| Shape | When |
|-------|------|
| `{status: :sent, <id_field>: <uuid>, response_code: 2xx}` | Success |
| `{status: :failed, error: <msg>, response_code: 4xx}` | Terminal 4xx (no retry) |
| `{status: :skipped, reason: <string>}` | Feature flag off |
| **raises** `Ecosystem::TransientFailure` | 5xx retried but exhausted, or network error retried but exhausted |
| **raises** `Ecosystem::CircuitOpen` | Breaker tripped — short-circuit, no HTTP made |

Sidekiq jobs that consume these clients should let `TransientFailure`
+ `CircuitOpen` bubble — Sidekiq's own retry queue handles back-off
across the cooldown window.

### What lives WHERE

| Concern | Lives in |
|---------|----------|
| HTTP wiring (Faraday adapter, headers, timeouts) | `lib/ecosystem/<service>_client.rb` |
| Per-adapter rate-limit detection | `lib/ecosystem/<service>_client.rb` |
| Cross-adapter circuit-breaker primitive | `lib/ecosystem/circuit_breaker.rb` (shared) |
| Singleton registration + lifecycle | `config/initializers/ecosystem_clients.rb` |
| Sidekiq job using the client | `app/jobs/...` (NEVER instantiates a fresh client — always reads `<Client>.instance`) |
| Tests | `test/lib/ecosystem/<service>_client_test.rb` — uses `Faraday::Adapter::Test` (the Hub IS a third-party service per the mock policy) |

### Mocking policy reminder

The mock policy in `CODING_STANDARDS_TESTING_LIVE.md` says: **don't
mock what you own.** Ecosystem services (Hub, Workflow Engine, etc.)
are NOT owned by this engine — they are external services. Mocking
their HTTP responses via `Faraday::Adapter::Test` is the canonical,
correct approach. (Local Postgres + Redis are different — those are
hit live per the same mock policy.)

## When to read this

Before:

- Writing any new `lib/ecosystem/<service>_client.rb` (Workflow Engine, Webhook Engine, Invoice Recon, etc. — Phase 2 batches 016+)
- Writing any Sidekiq job that posts to an ecosystem service
- Adding a new retry rule, circuit-breaker policy, or singleton lifecycle hook to the existing initializer
- Debugging a "client made an HTTP call after the breaker opened" report

## Cross-references

- PRD §6 (Connectors / Integrations), §6b (Ecosystem Integration Points), §2.2 (Standalone-first invariant)
- `.claude/rules/architecture_rules.md` — "Shared infra: Faraday 2 singleton clients in `lib/ecosystem/`"
- `.claude/rules/CODING_STANDARDS_TESTING_LIVE.md` — Mock policy ("Mock ONLY These: Third-party APIs, ...")
- Related foundation docs: `tenant-snapshot-shape.md` (snapshots flow through Hub events via DeliveryPayload)
