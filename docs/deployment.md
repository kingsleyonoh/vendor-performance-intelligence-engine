# Deployment — Vendor Performance Intelligence Engine

> PRD §10. Complements `docker-compose.prod.yml` (deployment artifact) and the
> `vps-deploy` / `nas-deploy` skills. This doc captures intent + invariants the
> CI/CD pipeline and future operators must preserve.

## Topology

- **Single Hetzner VPS** — `vendors.kingsleyonoh.com`.
- **Postgres 16** runs as a Docker service on the SAME host (colocated).
- **Redis 7** runs as a Docker service on the SAME host (colocated).
- **Traefik** reverse-proxies with Let's Encrypt TLS.
- **GitHub Actions → GHCR → VPS pull** is the deployment channel. See
  `CODING_STANDARDS_DOMAIN.md` — "Deployment Flow (Dev → Production)".

## Region / Latency Pinning (PRD §10 + `CODING_STANDARDS_DOMAIN.md`)

**Invariant: application compute and the Postgres instance MUST live in the
same region.** `CODING_STANDARDS_DOMAIN.md` — "Pin Compute to Data Region" —
mandates this because unmatched regions add 50–100ms per query. For a scoring
engine that queries `vendor_signals` for every composite recompute, this
compounds into visible latency regressions.

### Current state: automatically satisfied

Because Postgres is a colocated Docker service on the SAME Hetzner VPS as the
Rails app (not a managed DB on another provider), the "pin compute to data
region" rule is a no-op today — both live in the same Docker network, same
disk, same host. The unix-domain-socket-equivalent latency (<1ms round-trip)
removes the problem at the topology level.

### Invariants for any future migration

If Postgres ever moves off the VPS (e.g. Hetzner Managed DB, AWS RDS,
Supabase, Neon), the application deployment MUST:

1. **Deploy to the same region as the new Postgres instance.** No exceptions.
   Hetzner Managed DB in `eu-central` → app in `eu-central`. Supabase in
   `eu-west-1` → app in `eu-west-1`.
2. **Set region explicitly in deployment config** (Traefik labels,
   `docker-compose.prod.yml` placement constraints, or the platform's
   region setting — whichever the target host uses).
3. **Add a region-check to the deployment pipeline** (GitHub Actions job that
   fails the deploy if `APP_REGION != DATABASE_REGION`).
4. **Log a Deviations Log entry in `docs/progress.md`** capturing the new
   topology, the measured round-trip latency (post-migration), and any
   mitigation (read replica, connection pooler).

### Multi-region is NOT planned

VPI targets mid-market manufacturers in the EU (PRD §1). A single EU region
is sufficient. If multi-region is ever proposed, treat it as a PRD-level
change — file a Deviations Log entry BEFORE implementation.

## Related

- `docker-compose.prod.yml` — production compose stack (Traefik + app + Postgres + Redis).
- `.env.example` — production-shape env vars.
- PRD §10 — Deployment.
- PRD §10b — Observability.
- `CODING_STANDARDS_DOMAIN.md` — "Pin Compute to Data Region", "Deployment Flow".
