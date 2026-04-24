# PostgreSQL / Redis Port Conflicts with Sibling Dev Stacks

- **Symptom:** `docker compose up -d postgres redis` fails with `Error response from daemon: driver failed programming external connectivity on endpoint vpi-postgres-dev ... Bind for 0.0.0.0:5432 failed: port is already allocated`. Tests silently connect to the wrong PostgreSQL (another project, different schema) when the port does happen to be free.
- **Cause:** The local machine runs other portfolio/dev projects that publish PostgreSQL on 5432 (e.g. `swarm-dev-postgres`, `klevar-docs-postgres`) or a system-installed PostgreSQL. Redis has similar pressure on 6379.
- **Solution (baked into `docker-compose.yml`):**
  ```yaml
  postgres:
    ports:
      - "5434:5432"   # host 5434 → container 5432
  redis:
    ports:
      - "6384:6379"   # host 6384 → container 6379
  ```
  Inside the compose network, services still reach each other as `postgres:5432` and `redis:6379` (DNS via compose). Only the host-side published port changes. From the host shell use `psql -h localhost -p 5434 -U vpi_user vpi_development` and `redis-cli -h localhost -p 6384`.
- **Why 5434/6384 specifically:** 5440 was considered but is already mapped by `swarm-dev-postgres` as a secondary binding (`0.0.0.0:5440->5432/tcp`). Scanning the live Docker ports showed 5432, 5436, 5440, 5446 occupied and 6379, 6381, 6382, 6383, 6385 occupied. 5434 and 6384 were free.
- **Discovered in:** vendor-performance-intelligence-engine Batch 001 dev-container setup, 2026-04-24. Original sighting 2026-04-23 was speculative (system Postgres only); actual collision hit in Batch 001 came from Docker Desktop sibling containers.
- **Affects:** Any dev machine with other portfolio projects running. Rails 8 + pg gem / Sidekiq + redis-rb.
