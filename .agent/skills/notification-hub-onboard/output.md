# Notification Hub Onboarding — VPI Operator Runbook

> Generated artifact for the `notification-hub-onboard` skill — PRD §6.1, §7b, §13.2.
> The Vendor Performance Intelligence Engine emits **risk-band-change events** through the Notification Hub. Hub fanout (subscriptions → email + Telegram channels) is owned by the Hub, not VPI. This runbook is what an operator runs against a target Hub deployment to register VPI as a tenant + load all 9 templates.

## Prerequisites

- A running Notification Hub deployment with admin API reachable.
- `NOTIFICATION_HUB_URL` and a Hub admin API key (only used by this runbook — VPI itself uses a tenant-scoped key, see step 4).
- VPI codebase checked out — needed to read the Liquid template files in `test/fixtures/hub_templates/`.

## Step 1 — Create a Hub tenant for VPI

```bash
curl -X POST "$NOTIFICATION_HUB_URL/api/admin/tenants" \
  -H "Authorization: Bearer $HUB_ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "slug": "vpi",
        "name": "Vendor Performance Intelligence Engine",
        "description": "Risk-band alerts for procurement teams"
      }'
```

Capture the returned `api_key`. Set it on the VPI server as `NOTIFICATION_HUB_API_KEY`.

## Step 2 — Register the 9 templates

Each template uses the **DeliveryPayload** shape captured in `risk_alerts.delivery_payload` (frozen at alert creation per PRD §5.5 + §15 #12). Tokens reference `tenant.*`, `vendor.*`, `score.*`, `top_contributors.*`, `deep_links.*`. The Hub MUST register each template with `strict: true` so missing tokens fail loudly instead of silently emitting empty strings.

| Hub Template Id              | File (in VPI repo)                                       | Trigger                                |
|------------------------------|----------------------------------------------------------|----------------------------------------|
| `vpi-risk-escalation-email`  | `test/fixtures/hub_templates/vpi_risk_escalation_email.liquid` | Any → HIGH                       |
| `vpi-risk-critical-email`    | `test/fixtures/hub_templates/vpi_risk_critical_email.liquid`   | Any → CRITICAL                   |
| `vpi-risk-escalation-telegram`| `test/fixtures/hub_templates/vpi_risk_escalation_telegram.liquid` | Any → HIGH                  |
| `vpi-risk-critical-telegram` | `test/fixtures/hub_templates/vpi_risk_critical_telegram.liquid`| Any → CRITICAL                   |
| `vpi-risk-medium-email`      | `test/fixtures/hub_templates/vpi_risk_medium_email.liquid`     | LOW → MEDIUM                     |
| `vpi-risk-improvement-digest`| `test/fixtures/hub_templates/vpi_risk_improvement_digest.liquid`| Daily improvement digest        |
| `vpi-report-ready`           | `test/fixtures/hub_templates/vpi_report_ready.liquid`          | `vendor_reports.status` → ready  |
| `vpi-ingestion-stale`        | `test/fixtures/hub_templates/vpi_ingestion_stale.liquid`       | `ingestion_sources.last_successful_pull > 24h` |
| `vpi-alias-review`           | `test/fixtures/hub_templates/vpi_alias_review.liquid`          | Pending alias queue > 20         |

For each row above, run:

```bash
TEMPLATE_FILE="test/fixtures/hub_templates/<file>.liquid"
TEMPLATE_ID="<id>"
curl -X POST "$NOTIFICATION_HUB_URL/api/templates" \
  -H "X-API-Key: $NOTIFICATION_HUB_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(jq -n \
        --arg id "$TEMPLATE_ID" \
        --arg body "$(cat $TEMPLATE_FILE)" \
        '{template_id: $id, engine: "liquid", strict: true, body: $body}')"
```

(Or write a one-shot script that loops the 9 entries — the PRD does not mandate any particular shell tool.)

## Step 3 — Register subscription rules

The Hub maps event types to the templates above. VPI emits these event types:

| Event Type                       | Subscribed templates                                          |
|----------------------------------|---------------------------------------------------------------|
| `vendor.risk_band_changed`       | `vpi-risk-medium-email` (LOW→MEDIUM), `vpi-risk-escalation-email` (→HIGH), `vpi-risk-critical-email` (→CRITICAL), telegram pair for HIGH/CRITICAL |
| `vendor.risk_band_improved`      | `vpi-risk-improvement-digest` (daily aggregate)               |
| `vendor.report_ready`            | `vpi-report-ready`                                            |
| `vendor.ingestion_stale`         | `vpi-ingestion-stale`                                         |
| `vendor.alias_review_backlog`    | `vpi-alias-review`                                            |

Recipients (email addresses, Telegram chat ids) live on the Hub side. VPI sends only the event type + frozen `DeliveryPayload`; the Hub's rule engine does the fanout.

## Step 4 — Set environment variables on VPI

```bash
NOTIFICATION_HUB_ENABLED=true
NOTIFICATION_HUB_URL=https://notify.kingsleyonoh.com
NOTIFICATION_HUB_API_KEY=<from Step 1>
```

`NOTIFICATION_HUB_ENABLED` defaults to `false` (standalone-first per PRD §2.2). With it `false`, every dispatch returns `{status: :skipped, reason: "Hub disabled"}` and the alert is marked `delivered` locally — no events leave VPI. Setting it `true` requires the variables above to be present and a reachable Hub.

## Step 5 — Smoke test

After `NOTIFICATION_HUB_ENABLED=true` and a server restart (so `config/initializers/ecosystem_clients.rb` re-binds the singleton):

```bash
# Trigger a synthetic band crossing on a test tenant + vendor:
bin/rails runner 'puts Alerts::Dispatcher.on_band_crossing(score: VendorScore.last, previous_band: "low")'

# Watch Sidekiq for HubDispatchJob:
tail -f log/sidekiq.log | grep alerts.dispatch
```

A successful run shows `status='delivered', hub_event_id` populated on the new `risk_alerts` row. A failed run shows `status='failed'` and `last_error` populated; `FailedAlertRetryJob` retries every 30 minutes per PRD §7.

## Multi-tenant safety contract (PRD §15 #14 + §15 #15)

Every template MUST render against ≥2 tenants in CI. VPI ships `test/integration/template_binding_test.rb` which validates this for all 9 templates × `acme_gmbh_de` + `globex_inc_us`. Any missing token raises `Liquid::UndefinedVariable` and fails the build. This is the contract you inherit when accepting these templates into the Hub: do NOT modify them to inline tenant-specific literals (PRD §12 What-NOT — "tenant-identity leak"). Use only the tokens from the DeliveryPayload shape.
