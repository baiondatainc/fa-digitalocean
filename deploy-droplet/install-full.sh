#!/usr/bin/env bash
# install-full.sh — one-shot installer for the complete Future Advisor stack
# on a single droplet (web, api, forecast-py, forecast-agent, ingest-worker,
# live-agent, synthea-agent, librechat + Postgres/Timescale, Redis, Neo4j,
# MongoDB, Meilisearch, Caddy proxy).
#
# Run from the directory this script lives in, as root:
#   bash install-full.sh
#
# Flags:
#   --no-seed   Skip the Neo4j schema seed + Modelfile.dof registration.
#   --no-pull   Don't docker-pull before bring-up (use local images only).
#
# Idempotent — safe to re-run. Secrets in .env are preserved once generated.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

COMPOSE_FILE="docker-compose.full.yml"
ENV_FILE=".env"
EXAMPLE_FILE=".env.full.example"

SEED_NEO4J=1
DO_PULL=1
for arg in "$@"; do
  case "$arg" in
    --no-seed) SEED_NEO4J=0 ;;
    --no-pull) DO_PULL=0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

rand_hex() { openssl rand -hex "$1"; }

# rotate <KEY> <bytes>  → replaces the KEY= line with KEY=<fresh random hex>
# only when the current value matches a known placeholder (REPLACE_ME or
# CHANGE_ME_*). Leaves real values alone so re-running is safe.
rotate() {
  local key=$1 bytes=$2 val
  val=$(rand_hex "$bytes")
  # Use `#` as the sed delimiter so the ERE alternation `|` isn't treated as one.
  sed -i -E "s#^${key}=(REPLACE_ME.*|CHANGE_ME_.*)\$#${key}=${val}#" "$ENV_FILE"
}

echo "==> 1/7 Generate .env (if missing)"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$EXAMPLE_FILE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  rotate POSTGRES_PASSWORD 16
  rotate JWT_SECRET 32
  rotate FORECAST_SERVICE_TOKEN 32
  rotate AGENT_API_TOKEN 32
  rotate NEO4J_PASSWORD 16
  rotate LIBRECHAT_JWT_SECRET 32
  rotate LIBRECHAT_JWT_REFRESH_SECRET 32
  rotate CREDS_KEY 32
  rotate CREDS_IV 16
  rotate MEILI_MASTER_KEY 32
  echo "    generated $ENV_FILE"
  echo "    EDIT $ENV_FILE to set PUBLIC_ORIGIN, AGENT_LLM_API_KEY, FRED_API_KEY, etc."
else
  echo "    $ENV_FILE already exists — keeping"
  # Still rotate anything that's still a CHANGE_ME_* placeholder (e.g. the user
  # edited the example and ran the installer without regenerating secrets).
  rotate POSTGRES_PASSWORD 16
  rotate JWT_SECRET 32
  rotate FORECAST_SERVICE_TOKEN 32
  rotate AGENT_API_TOKEN 32
  rotate NEO4J_PASSWORD 16
  rotate LIBRECHAT_JWT_SECRET 32
  rotate LIBRECHAT_JWT_REFRESH_SECRET 32
  rotate CREDS_KEY 32
  rotate CREDS_IV 16
  rotate MEILI_MASTER_KEY 32
fi

set -a; source "$ENV_FILE"; set +a

echo "==> 2/7 Verify docker + registry login"
command -v docker >/dev/null 2>&1 || {
  echo "docker not installed. On the droplet: curl -fsSL https://get.docker.com | sh && systemctl enable --now docker"
  exit 1
}
if ! grep -q "registry.digitalocean.com" ~/.docker/config.json 2>/dev/null; then
  echo "    No DO registry creds in ~/.docker/config.json."
  echo "    From your laptop:   scp ~/.docker/config.json root@<droplet-ip>:/root/.docker/"
  echo "    Or on the droplet:  snap install doctl && doctl auth init && doctl registry login"
  exit 1
fi
echo "    registry creds present"

if [[ $DO_PULL -eq 1 ]]; then
  echo "==> 3/7 docker compose pull"
  docker compose -f "$COMPOSE_FILE" pull
else
  echo "==> 3/7 skipped docker pull (--no-pull)"
fi

echo "==> 4/7 Bring up stack"
docker compose -f "$COMPOSE_FILE" up -d

echo "==> 5/7 Wait for Timescale + Neo4j"
for i in {1..24}; do
  pg_ok=$(docker exec fa-timescaledb pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 && echo 1 || echo 0)
  neo_ok=$(docker exec fa-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" "RETURN 1" >/dev/null 2>&1 && echo 1 || echo 0)
  if [[ "$pg_ok" == "1" && "$neo_ok" == "1" ]]; then
    echo "    Timescale + Neo4j are up"
    break
  fi
  sleep 5
done

echo "==> 6/7 Neo4j schema seed"
if [[ $SEED_NEO4J -eq 1 ]]; then
  if [[ -f neo4j_export/schema.cypher ]]; then
    docker exec -i fa-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" -f /import/schema.cypher || true
  else
    echo "    (no neo4j_export/schema.cypher — skipping)"
  fi
  # Register the Cypher LLM inside an existing Ollama container if present.
  # Only applies when CHAT_LLM_PROVIDER=ollama. Harmless no-op otherwise.
  if [[ -f Modelfile.dof ]] && docker ps --format '{{.Names}}' | grep -q '^future-advisor-ollama$'; then
    docker cp Modelfile.dof future-advisor-ollama:/tmp/Modelfile.dof
    docker exec future-advisor-ollama ollama create futureadvisor-cypher:latest -f /tmp/Modelfile.dof || true
  fi
else
  echo "    skipped (--no-seed)"
fi

echo "==> 7/7 Status"
docker compose -f "$COMPOSE_FILE" ps

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
cat <<EOF

Done.

Public URLs (via Caddy on 80/443, PUBLIC_ORIGIN=${PUBLIC_ORIGIN:-unset}):
  App:        ${PUBLIC_ORIGIN:-http://$IP}/
  GraphQL:    ${PUBLIC_ORIGIN:-http://$IP}/graphql
  LibreChat:  ${PUBLIC_ORIGIN:-http://$IP}/chat

Health checks:
  curl -s ${PUBLIC_ORIGIN:-http://$IP}/graphql -o /dev/null -w 'graphql: %{http_code}\n'
  docker exec fa-api         node -e "fetch('http://127.0.0.1:4000/health').then(r=>r.text()).then(console.log)"
  docker exec fa-forecast-py python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8000/health').read().decode())"

Logs:
  docker compose -f $COMPOSE_FILE logs -f api
  docker compose -f $COMPOSE_FILE logs -f web
  docker compose -f $COMPOSE_FILE logs -f ingest-worker
EOF
