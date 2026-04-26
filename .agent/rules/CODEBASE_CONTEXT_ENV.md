# Vendor Performance Intelligence Engine — Environment Variables

> Split from `CODEBASE_CONTEXT.md` to keep that file under 10K chars. Canonical source: `.env.example` + PRD §14.
> Last updated: 2026-04-23

| Variable | Purpose | Source |
|----------|---------|--------|
| `RAILS_ENV`, `RAILS_MASTER_KEY`, `SECRET_KEY_BASE`, `PORT`, `RAILS_LOG_LEVEL` | Rails runtime | `.env` / hosting env |
| `DATABASE_URL`, `DATABASE_POOL` | PostgreSQL connection | `.env` |
| `REDIS_URL`, `SIDEKIQ_CONCURRENCY` | Redis + Sidekiq | `.env` |
| `SELF_REGISTRATION_ENABLED`, `API_KEY_PREFIX` | Tenant management | `.env` |
| `ALLOWED_ORIGINS`, `HUB_INGRESS_SECRET` | CORS + Hub HMAC | `.env` |
| `DEFAULT_WINDOW_DAYS`, `DEFAULT_TIME_DECAY_HALF_LIFE_DAYS`, `ALERT_DEDUP_WINDOW_HOURS`, `MAX_SIGNAL_BACKFILL_DAYS`, `INGESTION_BATCH_SIZE`, `SCORER_MAX_SIGNALS_PER_COMPUTE`, `AUTO_MATCH_FUZZY_THRESHOLD`, `AUTO_CONFIRM_EXACT_TAXID` | Scoring + ingestion tunables | `.env` |
| `AUTO_SEED`, `AUTO_MIGRATE` | First-run automation | `.env` |
| `NOTIFICATION_HUB_ENABLED/URL/API_KEY` | Hub integration (optional) | `.env` |
| `WORKFLOW_ENGINE_ENABLED/URL/API_KEY` | Workflow Engine (optional) | `.env` |
| `WEBHOOK_ENGINE_ENABLED/URL/API_KEY` | Webhook Engine (optional) | `.env` |
| `INVOICE_RECON_ENABLED/URL/API_KEY` | Invoice Recon (optional) | `.env` |
| `CONTRACT_ENGINE_ENABLED/URL/API_KEY` | Contract Lifecycle REST (optional) | `.env` |
| `NATS_ENABLED/URL/CREDS_PATH/STREAM_NAME` | NATS JetStream subscriber (optional) | `.env` |
| `RECON_ENGINE_ENABLED/URL/API_KEY` | Transaction Recon (optional) | `.env` |
| `RAG_PLATFORM_ENABLED/URL/API_KEY` | RAG Platform enrichment (optional) | `.env` |
| `SENTRY_DSN`, `AXIOM_TOKEN`, `AXIOM_DATASET`, `POSTHOG_API_KEY`, `POSTHOG_HOST`, `PROMETHEUS_ENABLED`, `METRICS_BASIC_AUTH_USER/PASS` | Observability | `.env` |
| `REPORT_RETENTION_DAYS`, `PDF_RENDER_TIMEOUT_SECONDS`, `REPORT_STORAGE_PATH` | Report generation | `.env` |

> **Feature-flag convention:** every ecosystem integration is `{SERVICE}_ENABLED=false` by default. The core engine runs fully standalone without any ecosystem wiring (PRD §2.2).
