# sumni-finance-deployment

Infrastructure and deployment configuration for sumni-finance. Deploys a Go backend, Next.js frontend, PostgreSQL, and Grafana Alloy (log shipping) to a single VPS via GitHub Actions.

---

## Architecture

```
GitHub Actions
    │
    ├─ setup-vps.yml     → runs once: installs Nginx + TLS on the VPS
    ├─ deploy.yml        → deploys infra services (db, alloy) to VPS
    └─ deploy-backend.yml → pulls & restarts the backend container
                            (triggered by repository_dispatch from the backend repo)

VPS (Ubuntu 24.04)
    │
    Nginx (TLS termination)
    ├─ deadun.site        → frontend  :3000  (Docker, localhost-only)
    └─ api.deadun.site    → backend   :4000  (Docker, public port)

Docker Compose  (/opt/sumni-finance/docker/)
    ├─ db        PostgreSQL 17
    ├─ backend   Go API (image from GHCR)
    ├─ frontend  React Vite (image from GHCR)
    └─ alloy     Grafana Alloy — ships Docker logs → Grafana Cloud Loki
```

---

## GitHub Actions workflows

### `setup-vps.yml` — run once

Copies `scripts/` to the VPS and runs `setup.sh` + `install-docker.sh`.

- Installs Nginx, issues Let's Encrypt TLS certs for frontend and API domains, writes the final Nginx site config, and sets up auto-renewal.
- Installs Docker + Docker Compose plugin.

**Inputs (workflow_dispatch):**

| Input | Default | Description |
|-------|---------|-------------|
| `domain_frontend` | `deadun.site` | Frontend domain |
| `domain_api` | `api.deadun.site` | API domain |

---

### `deploy.yml` — deploy infra services

Copies `docker/docker-compose.yml` and `docker/grafana/` to the VPS, then starts the `db` and `alloy` services.

**Trigger:** `workflow_dispatch`

---

### `deploy-backend.yml` — deploy backend

Pulls the latest backend image from GHCR and restarts the `backend` container without touching other services.

**Triggers:**
- `workflow_dispatch` (manual, with `image_tag` input)
- `repository_dispatch` with type `deploy-backend` (sent by the backend repo's CI on merge to main)

---

## GitHub Actions secrets & variables

Configure these in **Settings → Environments → staging**.

### Secrets

| Name | Description |
|------|-------------|
| `VPS_HOST` | VPS IP address or hostname |
| `VPS_USER` | SSH username on the VPS |
| `VPS_SSH_KEY` | Private SSH key for VPS access |
| `SSH_PASSWORD` | SSH password (used by setup-vps only, for sudo) |
| `DB_PASSWORD` | PostgreSQL password |
| `LOKI_URL` | Grafana Cloud Loki push URL |
| `LOKI_USERNAME` | Grafana Cloud Loki username |
| `LOKI_PASSWORD` | Grafana Cloud Loki API key / password |
| `CERTBOT_EMAIL` | Email for Let's Encrypt registration |

### Variables

| Name | Description |
|------|-------------|
| `DB_USER` | PostgreSQL username |
| `DB_NAME` | PostgreSQL database name |
| `DB_HOST` | DB host as seen by the backend (e.g. `db`) |
| `DB_PORT` | DB port (e.g. `5432`) |
| `CORS_ALLOWED_ORIGINS` | Comma-separated allowed origins for the backend CORS config |

---

## Viewing logs

Logs are shipped to **Grafana Cloud Loki** via Alloy. Open your Grafana Cloud instance and go to **Explore → Loki**.

### Tail all backend logs
```logql
{container="sumni-finance-backend"}
```

### Search by correlation_id
```logql
{container="sumni-finance-backend"} | json | correlation_id="<your-id>"
```

### Filter by level
```logql
{container="sumni-finance-backend"} | json | level="error"
```

> The backend must emit structured JSON logs with a `correlation_id` field for the label filters to work.
