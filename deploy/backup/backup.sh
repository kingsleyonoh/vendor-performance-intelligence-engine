#!/usr/bin/env bash
# Vendor Performance Intelligence Engine — daily Postgres backup
#
# Steps:
#   1. pg_dump (custom format, compressed) into ${BACKUP_DIR}/vpi-${TIMESTAMP}.dump
#   2. gpg-encrypt with BACKUP_ENCRYPTION_PASSPHRASE → .dump.gpg
#   3. rclone-upload to b2:${BACKBLAZE_B2_BUCKET}/postgres/ (when configured)
#   4. prune local + remote artifacts older than BACKUP_RETENTION_DAYS
#
# Required env (production):
#   DATABASE_URL                — postgres://user:pass@host:port/dbname
#   BACKUP_ENCRYPTION_PASSPHRASE
#   BACKBLAZE_B2_KEY_ID
#   BACKBLAZE_B2_APP_KEY
#   BACKBLAZE_B2_BUCKET
#
# Optional flags:
#   --dry-run        do everything except actually upload to B2 + delete remote
#
# Standalone-first: when BACKBLAZE_B2_* vars are unset, the script
# completes the local dump + encrypt + retention prune and logs a
# warning that remote upload was skipped.

set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    *) echo "WARN: unknown arg '${arg}'" >&2 ;;
  esac
done

log() { printf '[backup %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() { log "FATAL: $*" >&2; exit 1; }

: "${BACKUP_DIR:=/var/vpi/backups}"
: "${BACKUP_RETENTION_DAYS:=30}"
mkdir -p "${BACKUP_DIR}"

[ -n "${DATABASE_URL:-}" ] || fail "DATABASE_URL is not set"

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP_FILE="${BACKUP_DIR}/vpi-${TIMESTAMP}.dump"
ENC_FILE="${DUMP_FILE}.gpg"

# ---- Step 1: pg_dump ----
log "starting pg_dump → ${DUMP_FILE}"
pg_dump --format=custom --compress=9 --no-owner --no-privileges \
        --file="${DUMP_FILE}" "${DATABASE_URL}" \
  || fail "pg_dump failed"
DUMP_BYTES="$(stat -c%s "${DUMP_FILE}" 2>/dev/null || stat -f%z "${DUMP_FILE}")"
log "pg_dump complete (${DUMP_BYTES} bytes)"

# Sanity: dump should never be 0 bytes on a non-empty DB
[ "${DUMP_BYTES}" -gt 0 ] || fail "pg_dump produced an empty file"

# ---- Step 2: encrypt ----
if [ -n "${BACKUP_ENCRYPTION_PASSPHRASE:-}" ]; then
  log "encrypting → ${ENC_FILE}"
  printf '%s' "${BACKUP_ENCRYPTION_PASSPHRASE}" | \
    gpg --batch --yes --quiet --pinentry-mode loopback \
        --passphrase-fd 0 --symmetric --cipher-algo AES256 \
        -o "${ENC_FILE}" "${DUMP_FILE}" \
    || fail "gpg encryption failed"
  rm -f "${DUMP_FILE}"
  ARTIFACT="${ENC_FILE}"
  log "encrypted artifact ready"
else
  log "WARN: BACKUP_ENCRYPTION_PASSPHRASE not set — uploading UNENCRYPTED dump"
  ARTIFACT="${DUMP_FILE}"
fi

# ---- Step 3: upload to Backblaze B2 ----
if [ -n "${BACKBLAZE_B2_KEY_ID:-}" ] && [ -n "${BACKBLAZE_B2_APP_KEY:-}" ] && [ -n "${BACKBLAZE_B2_BUCKET:-}" ]; then
  if [ "${DRY_RUN}" -eq 1 ]; then
    log "DRY-RUN: would upload ${ARTIFACT} → b2:${BACKBLAZE_B2_BUCKET}/postgres/"
  else
    log "uploading ${ARTIFACT} → b2:${BACKBLAZE_B2_BUCKET}/postgres/"
    # rclone configuration via env (no config file required).
    export RCLONE_CONFIG_B2_TYPE=b2
    export RCLONE_CONFIG_B2_ACCOUNT="${BACKBLAZE_B2_KEY_ID}"
    export RCLONE_CONFIG_B2_KEY="${BACKBLAZE_B2_APP_KEY}"
    rclone copy "${ARTIFACT}" "b2:${BACKBLAZE_B2_BUCKET}/postgres/" \
        --no-traverse --progress \
      || fail "rclone upload failed"
    log "upload complete"
  fi
else
  log "WARN: Backblaze B2 credentials not set — skipping remote upload (local-only mode)"
fi

# ---- Step 4: retention prune ----
log "pruning local artifacts older than ${BACKUP_RETENTION_DAYS} days"
find "${BACKUP_DIR}" -type f -name 'vpi-*.dump*' -mtime "+${BACKUP_RETENTION_DAYS}" -print -delete \
  || log "WARN: local prune raised non-zero (continuing)"

if [ -n "${BACKBLAZE_B2_BUCKET:-}" ] && [ "${DRY_RUN}" -eq 0 ]; then
  log "pruning remote artifacts older than ${BACKUP_RETENTION_DAYS} days"
  rclone delete "b2:${BACKBLAZE_B2_BUCKET}/postgres/" \
      --min-age "${BACKUP_RETENTION_DAYS}d" \
    || log "WARN: remote prune raised non-zero (continuing)"
fi

log "backup run complete"
