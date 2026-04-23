# PostgreSQL Port 5432 Conflict with System Install

- **Symptom:** Docker PostgreSQL fails to start with "address already in use", or tests silently connect to the system PostgreSQL instead of the Docker one (schema mismatch, missing extensions like `pg_partman`, empty tables).
- **Cause:** The local machine has a system-installed PostgreSQL listening on the default port 5432. Docker's mapped port clashes or the shell picks up the wrong `DATABASE_URL` at connection time.
- **Solution:** Map Docker PostgreSQL to port 5440 via `docker-compose.override.yml`:
  ```yaml
  services:
    postgres:
      ports:
        - "5440:5432"
  ```
  Then set `DATABASE_URL=postgresql://vpi_user:vpi@localhost:5440/vpi_development` in `.env.local`. Leaves the system PostgreSQL untouched on 5432.
- **Discovered in:** vendor-performance-intelligence-engine bootstrap, 2026-04-23.
- **Affects:** Any dev machine with a system PostgreSQL install (common on macOS via Homebrew, Linux via apt). Rails 8 + pg gem.
