# Foundation: API Error Response Shape

## What it establishes

Every JSON response emitted by a controller under `Api::*` — including errors raised from middleware (Rack::Attack, ApiKeyAuthenticator) — conforms to the JSON:API-style envelope defined in **PRD §8b**. Consumers (ecosystem services, Hub event ingress, the Operator UI) parse one shape for every non-2xx response.

## Files

- `lib/errors/json_api_error.rb` — frozen code constants + `http_status_for(code)` lookup
- `app/controllers/api/base_controller.rb` — `render_api_error` helper + `rescue_from` handlers that render the envelope
- `config/initializers/rack_attack.rb` — 429 responses emit the same envelope via `Rack::Attack.throttled_responder`
- `test/lib/errors/json_api_error_test.rb` — code → HTTP status invariants
- `test/controllers/api/base_controller_test.rb` — rescue_from path assertions

## Contract

### Response body shape

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Human-readable message",
    "details": [
      { "path": "signal_code", "issue": "unknown signal code 'foo.bar'" }
    ]
  }
}
```

- `code` — one of the 8 canonical strings below. UPPER_SNAKE_CASE, never localized.
- `message` — single human-readable string, safe to surface in an error toast.
- `details` — optional array of `{path, issue}` objects. Present for `VALIDATION_ERROR`; omitted otherwise unless the caller needs field-level context.

### The 8 canonical codes + HTTP status mapping

| Code | HTTP | When |
|------|------|------|
| `VALIDATION_ERROR` | 400 | Request body fails dry-validation / ActiveRecord validation |
| `UNAUTHORIZED` | 401 | Missing/invalid `X-API-Key`, missing `Current.tenant`, HMAC failure |
| `FORBIDDEN` | 403 | Authenticated but ActionPolicy denies the action (role/scope check fails) |
| `NOT_FOUND` | 404 | Resource absent **OR** resource belongs to a different tenant |
| `CONFLICT` | 409 | Unique constraint violation, duplicate `source_event_id`, scoring-rule activation collision |
| `RATE_LIMITED` | 429 | Rack::Attack throttle tripped |
| `INTERNAL_ERROR` | 500 | Unhandled exception (Sentry-reported; message scrubbed of internals) |
| `SERVICE_UNAVAILABLE` | 503 | Upstream ecosystem adapter unreachable + circuit breaker open |

### Rules

1. **NEVER return 403 for a cross-tenant access attempt.** Return 404. Revealing existence is itself a leak.
2. **NEVER surface stack traces, class names, or internal column names** in `message`. Log them; emit a generic human message.
3. **ALWAYS pass through `render_api_error(code, status: nil, message: nil, details: nil)`** — never hand-construct the envelope inline. Status is looked up from `JsonApiError.http_status_for(code)` when omitted.
4. **Rack middleware** that needs to emit errors (auth, rate limit) builds the same envelope — no separate error schema for middleware vs controller.
5. Controllers under `Api::*` inherit from `Api::BaseController` to receive `rescue_from` handlers for the common cases (`ActiveRecord::RecordNotFound` → 404, `ActiveRecord::RecordInvalid` → 400, `ActionPolicy::Unauthorized` → 403).

## When to read this

Before:
- Creating a new `Api::*Controller`
- Adding a `rescue_from` block
- Emitting a JSON error from a Rack middleware
- Writing a test that asserts against an error response
- Extending the error taxonomy (adding a new code must update `JsonApiError`, PRD §8b, and this file)

## Cross-references

- Related patterns: `.agent/knowledge/patterns/` (TBD)
- Related modules: `app/controllers/api/` + `lib/errors/`
- PRD: §8b (Error Response Format), §9 (Project Structure)
