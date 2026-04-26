# Vendor Performance Intelligence Engine — Daily Postgres backup container
#
# Runs `pg_dump`, encrypts the dump with gpg (symmetric AES-256), uploads
# the encrypted artifact to Backblaze B2 via `rclone`, and prunes
# artifacts older than BACKUP_RETENTION_DAYS (default 30).
#
# Designed for daily cron via `supercronic` (a no-fork cron implementation
# better suited to PID-1 in containers than crond). Falls back to
# `local-only` mode if Backblaze B2 credentials are absent — useful for
# local smoke tests via `docker compose run --rm postgres-backup ./backup.sh --dry-run`.
#
# PRD §10 Backups requirement.
FROM alpine:3.20

# Install pg_dump (postgresql-client, version-pinned to 16 to match the
# docker-compose postgres:16-alpine service), gpg for encryption, rclone
# for B2 upload, supercronic for cron, ca-certificates for HTTPS, bash
# (alpine ships ash, but our backup script uses bashisms), and tini for
# clean PID-1 signal forwarding.
RUN apk add --no-cache \
      postgresql16-client \
      gnupg \
      rclone \
      ca-certificates \
      bash \
      tini \
      tzdata && \
    addgroup -S vpi-backup && \
    adduser -S -G vpi-backup -h /home/vpi-backup vpi-backup

# supercronic — install as a static binary
ARG SUPERCRONIC_VERSION=v0.2.29
ARG SUPERCRONIC_SHA1=cd48d45c4b10f3f0bfdd3a57d054cd05ac96812b
ADD --chown=root:root --chmod=0755 \
    https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64 \
    /usr/local/bin/supercronic

WORKDIR /home/vpi-backup

COPY --chown=vpi-backup:vpi-backup backup.sh /home/vpi-backup/backup.sh
COPY --chown=vpi-backup:vpi-backup crontab    /home/vpi-backup/crontab
RUN chmod +x /home/vpi-backup/backup.sh

# Backups directory (mounted as a volume in compose so dumps survive
# restarts when running in `local-only` mode).
RUN mkdir -p /var/vpi/backups && chown vpi-backup:vpi-backup /var/vpi/backups

USER vpi-backup
ENV BACKUP_DIR=/var/vpi/backups \
    BACKUP_RETENTION_DAYS=30 \
    PGCONNECT_TIMEOUT=10

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["supercronic", "/home/vpi-backup/crontab"]
