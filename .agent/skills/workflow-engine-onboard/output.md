# Workflow Engine Onboarding — VPI Operator Runbook

> Generated artifact for the `workflow-engine-onboard` skill — PRD §6.2, §13.2.
> The Vendor Performance Intelligence Engine fires a Workflow Automation Engine execution alongside every HIGH/CRITICAL band-crossing alert (`Alerts::WorkflowEscalationJob`, see `app/jobs/alerts/workflow_escalation_job.rb`). The Workflow Engine owns the multi-step DAG (assign owner, request mitigation plan, schedule review). VPI only triggers the workflow + supplies the frozen alert context.

## Prerequisites

- A running Workflow Automation Engine deployment with admin API reachable.
- `WORKFLOW_ENGINE_URL` and an admin API key for tenant + workflow registration.

## Step 1 — Create a Workflow Engine tenant for VPI

```bash
curl -X POST "$WORKFLOW_ENGINE_URL/api/admin/tenants" \
  -H "Authorization: Bearer $WORKFLOW_ADMIN_KEY" \
  -H "Content-Type: application/json" \
  -d '{
        "slug": "vpi",
        "name": "Vendor Performance Intelligence Engine"
      }'
```

Capture the returned `api_key`. Set it on VPI as `WORKFLOW_ENGINE_API_KEY`.

## Step 2 — Register the escalation workflow

VPI calls `POST /api/workflows/:id/execute` with the alert payload. The workflow id is configured via `WORKFLOW_ENGINE_ESCALATION_WORKFLOW_ID` (default: `vpi-risk-escalation-default`). Register a workflow with that id:

```bash
curl -X POST "$WORKFLOW_ENGINE_URL/api/workflows" \
  -H "X-API-Key: $WORKFLOW_ENGINE_API_KEY" \
  -H "Content-Type: application/json" \
  -d @./.agent/skills/workflow-engine-onboard/sample_workflow.json
```

The shipped `sample_workflow.json` is illustrative — operators should adapt the steps (Slack channel, JIRA project, escalation rotation) to their own infrastructure. The contract VPI relies on is only:

- The workflow id matches `WORKFLOW_ENGINE_ESCALATION_WORKFLOW_ID`.
- The Engine accepts the payload shape VPI sends (`{alert_id, tenant, vendor, score, band_change}` — frozen from `risk_alerts.delivery_payload`).
- A successful execute returns `{execution_id: "<id>", ...}` with `2xx` status. VPI persists the execution_id to `risk_alerts.workflow_execution_id`.

## Step 3 — Set environment variables on VPI

```bash
WORKFLOW_ENGINE_ENABLED=true
WORKFLOW_ENGINE_URL=https://workflows.kingsleyonoh.com
WORKFLOW_ENGINE_API_KEY=<from Step 1>
WORKFLOW_ENGINE_ESCALATION_WORKFLOW_ID=vpi-risk-escalation-default
```

`WORKFLOW_ENGINE_ENABLED` defaults to `false` per PRD §2.2 (standalone-first). With it `false`, every escalation returns `{status: :skipped, reason: "Workflow Engine disabled"}` and the alert flows through Hub-only delivery. The core scoring engine is unchanged.

## Step 4 — Smoke test

```bash
# Force a HIGH/CRITICAL band crossing in a non-prod tenant and watch Sidekiq:
tail -f log/sidekiq.log | grep alerts.escalation
```

Expected: a single `WorkflowEscalationJob` fires per HIGH/CRITICAL alert, persists `workflow_execution_id`, audit log records `alerts#escalated` with the execution id.

## Snapshot-freezing contract (PRD §15 #12)

The escalation job reads ONLY from `risk_alerts.delivery_payload` (FROZEN at alert creation by `Alerts::CapturePayload`). It MUST NEVER re-query `tenants`, `vendors`, or `vendor_scores`. This means: a tenant rename or vendor merge between alert creation and workflow execute (even days later, on retry) MUST NOT change the payload sent to the Workflow Engine. The frozen-payload contract makes escalation history legally defensible.

If you customize `sample_workflow.json` to add steps that reference tenant identity (e.g. a Slack message mentioning the tenant's display_name), pull from the `tenant.*` keys in the payload — never re-fetch from any other source.
