# BetterStack Uptime Monitoring — VPI

> Operations runbook for the BetterStack uptime probe configuration.
> PRD §10b, §13.3.

## What this monitors

External BetterStack monitor probes the production health endpoint every 60s
and alerts on failure. The endpoint is intentionally LIVE-ALLOWLISTED (no
X-API-Key required) so BetterStack can poll it without holding tenant
credentials.

## Probe configuration

| Field | Value |
|-------|-------|
| Monitor type | HTTP keyword |
| URL | `https://vendors.kingsleyonoh.com/api/health/ready` |
| Method | `GET` |
| Expected status | `200` |
| Expected body keyword | `"status":"ready"` |
| Frequency | every 60 seconds |
| Timeout | 10 seconds |
| Regions | DE (primary), US-East (secondary) |
| Auth | none (endpoint is allowlisted) |

The `/api/health/ready` endpoint runs the full readiness chain — database
connectivity, Redis connectivity, Sidekiq queue reachability — and returns
200 only when ALL checks pass. A 503 return indicates a dependency is
unavailable; BetterStack treats this as a downtime event.

## Alert routing

When BetterStack detects a failure (3 consecutive failed checks):

1. **Primary:** webhook → Notification Hub `vpi-uptime-alert` template
   → Telegram channel `@vpi-ops` (24/7 on-call rotation).
2. **Secondary:** email → `ops@kingsleyonoh.com` (digest, 5-minute aggregation).
3. **Status page:** the public status page at `status.kingsleyonoh.com`
   updates automatically from BetterStack's status API.

The Notification Hub `vpi-uptime-alert` template renders:

```
[VPI] {{tenant.display_name}} — readiness check failing
  Endpoint: {{probe.url}}
  Last successful: {{probe.last_success_at}}
  Failed regions: {{probe.failed_regions}}
  Triggered at: {{probe.triggered_at}}
```

## Escalation rules

| Severity | Trigger | Action |
|----------|---------|--------|
| WARNING | 1 failed probe | log only, no alert |
| MINOR | 2 consecutive failures | Telegram-only, no email |
| MAJOR | 3 consecutive failures (default) | Telegram + email + status page update |
| CRITICAL | 5+ consecutive failures OR 5+ minutes of downtime | page on-call (PagerDuty integration) |

Recovery: alerts auto-resolve when 2 consecutive checks succeed.

## Heartbeat URL (optional)

If we choose to ALSO use BetterStack heartbeat monitors (push from VPI to
BetterStack on a schedule), set `BETTERSTACK_HEARTBEAT_URL` in `.env` and
the `Monitors::HeartbeatJob` (Phase 4 if needed) will POST to it. As of
batch 028 we do not ship a heartbeat poster — the inbound HTTP probe is
sufficient because Puma being able to respond is itself the proof of life.

## Onboarding a new environment

1. In BetterStack dashboard, create a new HTTP keyword monitor with the
   fields above (substituting the new env's hostname).
2. Add the monitor to the `vpi-prod` group (or `vpi-staging`).
3. Set the alert routing to the appropriate Telegram channel + email.
4. Add the monitor's **public status page slug** to the rendered footer in
   `app/views/layouts/_application_footer.html.erb` so customer-visible
   incidents auto-reflect.

## Verification

After onboarding:

```bash
curl -i https://vendors.kingsleyonoh.com/api/health/ready
# Expected: HTTP/2 200, body contains {"status":"ready"}.

# Force a failure for end-to-end test (production rehearsal only):
docker compose -f docker-compose.prod.yml stop redis
# BetterStack should detect within 60s, fire Telegram alert within 90s.
docker compose -f docker-compose.prod.yml start redis
# Recovery alert within 60s.
```
