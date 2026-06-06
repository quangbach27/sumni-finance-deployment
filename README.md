# sumni-finance-deployment

## Stack

| Service  | Purpose                        | Port (server)     |
|----------|--------------------------------|-------------------|
| Backend  | Go API                         | 4000              |
| Loki     | Log storage & indexing         | internal only     |
| Promtail | Log collector (Docker → Loki)  | internal only     |
| Grafana  | Log viewer UI                  | 127.0.0.1:3001    |

Nginx terminates TLS and proxies the backend on port 4000.  
Grafana is **localhost-only** — access it via SSH tunnel.

---

## Initial setup

```bash
# 1. Set Nginx + TLS (run once on the server)
DOMAIN_FRONTEND=deadun.site DOMAIN_API=api.deadun.site EMAIL=you@email.com bash scripts/setup.sh

# 2. Create .env from example and set a strong password
cp .env.example .env
nano .env   # set GRAFANA_ADMIN_PASSWORD

# 3. Start all services
docker compose up -d
```

---

## Viewing logs in Grafana

**Access Grafana via SSH tunnel:**

```bash
ssh -L 3001:127.0.0.1:3001 user@your-server-ip
# Then open http://localhost:3001 in your browser
```

Login: `admin` / value of `GRAFANA_ADMIN_PASSWORD`

Go to **Explore → Loki datasource**.

### Tail all backend logs
```logql
{container="sumni-finance-backend"}
```

### Search by correlation_id
```logql
{container="sumni-finance-backend"} | json | correlation_id="<your-id>"
```

### Filter by log level + correlation_id
```logql
{container="sumni-finance-backend", level="error"} | json | correlation_id="<your-id>"
```

> **Note:** `correlation_id` is parsed at query time from JSON log lines.  
> Your backend must emit logs as JSON with a `correlation_id` field for this to work.

---

## Common commands

```bash
# Check service status
docker compose ps

# Stream backend logs (without Grafana)
docker compose logs -f backend

# Restart a single service
docker compose restart backend

# Stop everything
docker compose down
```
