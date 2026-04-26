# Postgres Backup Container — VPI

Daily `pg_dump` + GPG-encrypt + Backblaze B2 upload + 30-day retention prune.
Implements PRD §10 "Backups" requirement.

## Architecture

```
postgres ──┐
           │ pg_dump (custom format, compressed)
           ▼
       /var/vpi/backups/vpi-${TS}.dump
           │
           │ gpg --symmetric --cipher-algo AES256
           ▼
       /var/vpi/backups/vpi-${TS}.dump.gpg
           │
           │ rclone copy (Backblaze B2)
           ▼
       b2:${BUCKET}/postgres/vpi-${TS}.dump.gpg
```

A dedicated container (`postgres-backup` service in `docker-compose.prod.yml`)
runs `supercronic` as PID 1, firing `backup.sh` daily at **02:30 UTC**.

## Required env (production `.env`)

```
DATABASE_URL=postgresql://vpi_user:${POSTGRES_PASSWORD}@postgres:5432/vpi_production
BACKUP_ENCRYPTION_PASSPHRASE=<32+ random chars; rotate via deploy procedure>
BACKBLAZE_B2_KEY_ID=<from Backblaze B2 console>
BACKBLAZE_B2_APP_KEY=<from Backblaze B2 console>
BACKBLAZE_B2_BUCKET=vpi-postgres-backups
BACKUP_RETENTION_DAYS=30
```

Standalone-first: when `BACKBLAZE_B2_*` are unset, the container runs in
"local-only" mode — dumps + encrypts to the `backups_data` volume but
does NOT push remotely. Useful for local dev verification.

## Restore procedure

1. Pull the encrypted artifact from B2:
   ```
   rclone copy b2:${BUCKET}/postgres/vpi-${TS}.dump.gpg ./
   ```
2. Decrypt:
   ```
   gpg --batch --yes --pinentry-mode loopback \
       --passphrase "${BACKUP_ENCRYPTION_PASSPHRASE}" \
       -o vpi-${TS}.dump --decrypt vpi-${TS}.dump.gpg
   ```
3. Restore (DESTRUCTIVE — confirm target DB):
   ```
   pg_restore --clean --if-exists --no-owner --no-privileges \
              --dbname=postgresql://user:pass@host:5432/vpi_production \
              vpi-${TS}.dump
   ```

## Local smoke test

```
# Dry-run (no remote upload, no retention prune of remote)
docker compose -f docker-compose.prod.yml run --rm \
  -e DATABASE_URL=postgresql://vpi_user:dev@postgres:5432/vpi_development \
  postgres-backup ./backup.sh --dry-run

# Verify a dump landed under the named volume
docker volume inspect vendor-performance-intelligence-engine_backups_data
```

## Why supercronic instead of crond?

`supercronic` runs cron jobs without forking, captures stdout/stderr to
the parent process, and exits cleanly on SIGTERM. `crond` in alpine
spawns child processes that can leak after container restart and does
not pipe job output to the docker log driver consistently.

## Why rclone instead of the b2 CLI?

The official `b2` CLI requires Python 3 + a long pip dependency tree
(adds ~80 MB to the image). `rclone` is a single static Go binary that
ships with native B2 support in addition to S3, Azure, GCS — making
disaster recovery to a different object-storage provider trivial.
