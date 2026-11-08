# Droplet deployment

Two bundles live in this folder — pick the one that matches what the droplet
is supposed to run:

| Bundle                 | Compose file             | Installer           | Scope |
|------------------------|--------------------------|---------------------|-------|
| **Chatbot only**       | `docker-compose.yml`     | `install.sh`        | LibreChat + synthea-agent + Neo4j + MongoDB + Meilisearch |
| **Full application**   | `docker-compose.full.yml`| `install-full.sh`   | web + api + forecast-py + forecast-agent + ingest-worker + live-agent + synthea-agent + librechat + all data stores + Caddy proxy |

The full-stack bundle pulls every FA image from the DO container registry
(`registry.digitalocean.com/future-advisor/*`). Build + push them first with:

```bash
# from the alpha repo root
cd future-advisor && ./scripts/push-docker-do.sh            # api, web, forecast-py, forecast-agent, ingest-worker
TAG=latest ./scripts/push-docker-do.sh live-agent           # live-agent (not pushed by default)
cd ../synthea-neo4j && ./build-and-push.sh                  # synthea-agent
cd ../LibreChat    && ./build-and-push.sh                   # librechat
```

> **`probe`** on the registry is an ad-hoc diagnostic image — not wired into
> either compose file. Delete it or ignore it.

## Full application — quick start

```bash
# On the droplet, in /opt/future-advisor (or wherever this bundle lives):
cp .env.full.example .env     # install-full.sh will do this for you + generate random secrets
$EDITOR .env                  # set PUBLIC_ORIGIN, AGENT_LLM_API_KEY, FRED_API_KEY, etc.
bash install-full.sh
```

`install-full.sh` is idempotent: it generates missing secrets, pulls images,
brings the stack up, waits for Timescale + Neo4j, seeds the Neo4j schema,
and prints public URLs + health checks at the end. Re-run safely after any
`.env` or compose change.

Flags:
- `--no-pull`  skip `docker compose pull` (use already-loaded images)
- `--no-seed`  skip Neo4j schema seed + Ollama Modelfile registration

### What's exposed

| Port     | Service            | Notes |
|----------|--------------------|-------|
| 80, 443  | Caddy proxy        | TLS auto-cert if `PUBLIC_ORIGIN` is a domain |
| 7474     | Neo4j browser      | bound to `127.0.0.1` (use SSH tunnel) |
| 7687     | Neo4j Bolt         | bound to `127.0.0.1` |

The API, web, forecast-py, forecast-agent, Postgres, Redis, MongoDB,
Meilisearch, LibreChat and the workers are internal-only (reach them via the
proxy or `docker exec`). LibreChat is routed at `/chat` through Caddy — bind
it to a host port in `docker-compose.full.yml` if you’d rather hit `:3080`
directly.

### Database bootstrap (first deploy only)

The API’s Prisma migrations have to be applied once against the local
Timescale container:

```bash
docker exec -it fa-api sh -c '\
  cd /repo/packages/db-main-prisma && \
  ./node_modules/.bin/prisma migrate deploy'
```

### Rolling a new image

```bash
# bump IMAGE_TAG (or just the per-service *_TAG) in .env, then:
docker compose -f docker-compose.full.yml pull <service>
docker compose -f docker-compose.full.yml up -d <service>
```

---

# LibreChat — droplet deployment (chatbot only)

LibreChat UI + MongoDB + Meilisearch, pulling from the DO private registry.
Assumes the DoF agent (synthea-agent image) is already running on the droplet
on `:8001` (reached via `host.docker.internal`).

## Prereqs on the droplet (one-time)

```bash
# 1. Docker + compose
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker

# 2. doctl + registry login (so `docker pull` can read the private registry)
snap install doctl
doctl auth init                   # paste a PAT with read access
doctl registry login              # writes creds into ~/.docker/config.json
```

## Deploy

```bash
# From this directory on the droplet (e.g. /opt/librechat):
cp .env.example .env
# edit .env — generate the four secrets with `openssl rand -hex 32`
$EDITOR .env

docker compose pull
docker compose up -d
docker compose logs -f librechat        # first boot takes ~30s

# Health
curl -s http://localhost:3080 -o /dev/null -w "ui: %{http_code}\n"
curl -s http://localhost:8001/health    # the agent should already return {"status":"ok"}
```

LibreChat UI: `http://<droplet-ip>:3080`. Sign up, pick **"Department of Finance Knowledge Graph"** from the endpoint menu.

## Update to a newer image

```bash
# Repoint tag in docker-compose.yml OR just pull the floating :latest
docker compose pull librechat
docker compose up -d librechat          # recreates with the new image
```

## Reverse proxy + HTTPS (optional)

Put nginx or Caddy in front of :3080. Caddy one-liner — just drop a `Caddyfile`:
```
chat.your-domain.com {
    reverse_proxy localhost:3080
}
```

## What's NOT in this compose

- **synthea-agent** (`registry.digitalocean.com/future-advisor/synthea-agent:v1.1.0`)
  — you said the app is already running on the droplet. If you need to redeploy
  it, the agent env is in `../../RP/dockers/docker-compose.yml` (service `agent`).
- **Neo4j / Ollama / Redis / Postgres** — part of the "app already running".
  LibreChat does NOT talk to these directly; it only talks to the agent.

## Files in this bundle

| File | Purpose |
|---|---|
| `docker-compose.yml` | LibreChat + MongoDB + Meilisearch |
| `librechat.yaml` | Mounted into the container at `/app/librechat.yaml` — routes `DOF-KG` endpoint to the agent at `http://host.docker.internal:8001/v1` |
| `.env.example` | Secrets template; copy to `.env` |
| `README.md` | This file |

## Troubleshooting

- **UI loads but the DOF-KG endpoint 500s** — check that `curl http://host.docker.internal:8001/health` from inside the container returns `{"status":"ok"}`:
  ```bash
  docker compose exec librechat sh -c 'wget -qO- http://host.docker.internal:8001/health'
  ```
  If it fails, the agent isn't reachable. Confirm the agent is bound to `0.0.0.0:8001` on the host (not `127.0.0.1`) — on Linux, `host.docker.internal` resolves to the host gateway and then hits the host's port 8001.

- **`doctl registry login` works but `docker compose pull` says "pull access denied"** — the PAT used for `doctl auth init` needs `registry:read`. Regenerate at https://cloud.digitalocean.com/account/api/tokens with "Container Registry → Read" scope.

- **MongoDB fails to init with "InternalError: Not primary"** — remove the volume (`docker volume rm fa-librechat_mongo_data`) and re-up. Only safe on first boot.
