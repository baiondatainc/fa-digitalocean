#!/usr/bin/env bash
# install.sh — one-shot installer to bring the chatbot stack up on the droplet.
#
# Run from the directory this script lives in, as root:
#   bash install.sh
#
# Idempotent — safe to re-run.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "==> 1/6 Generate .env (if missing)"
if [[ ! -f .env ]]; then
  cp .env.example .env
  sed -i "s|^NEO4J_PASSWORD=.*|NEO4J_PASSWORD=$(openssl rand -hex 16)|" .env
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$(openssl rand -hex 32)|" .env
  sed -i "s|^JWT_REFRESH_SECRET=.*|JWT_REFRESH_SECRET=$(openssl rand -hex 32)|" .env
  sed -i "s|^CREDS_KEY=.*|CREDS_KEY=$(openssl rand -hex 32)|" .env
  sed -i "s|^CREDS_IV=.*|CREDS_IV=$(openssl rand -hex 16)|" .env
  sed -i "s|^MEILI_MASTER_KEY=.*|MEILI_MASTER_KEY=$(openssl rand -hex 32)|" .env
  echo "    .env generated"
else
  echo "    .env already exists — keeping"
fi

# Source for use further down
set -a; source .env; set +a

echo "==> 2/6 docker login to DO registry (registry.digitalocean.com)"
if ! grep -q "registry.digitalocean.com" ~/.docker/config.json 2>/dev/null; then
  echo "    No credentials in ~/.docker/config.json."
  echo "    scp them from your workstation:   scp ~/.docker/config.json root@<this-ip>:/root/.docker/config.json"
  echo "    or install doctl and run:         doctl registry login"
  exit 1
fi
echo "    registry creds present"

echo "==> 3/6 Pull images"
docker compose pull

echo "==> 4/6 Bring up stack"
docker compose up -d
echo "    waiting for Neo4j to be healthy (up to 2 min) ..."
for i in {1..24}; do
  if docker exec fa-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" "RETURN 1" >/dev/null 2>&1; then
    echo "    Neo4j is up"
    break
  fi
  sleep 5
done

echo "==> 5/6 Seed Neo4j — apply schema.cypher from the mounted /import"
docker exec -i fa-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" -f /import/schema.cypher || true

# Full data load is a second step — see README.md section "Load the graph".
# Running pg_to_neo4j.py against the mounted /import is the quickest option
# once Postgres is reachable; otherwise ship a pre-made snapshot.

echo "==> 6/6 Create Cypher model in the existing Ollama container"
# futureadvisor-cypher:latest is what the agent requests. Create it inside
# future-advisor-ollama using the bundled Modelfile.dof.
if docker exec future-advisor-ollama ollama list 2>/dev/null | grep -q "^futureadvisor-cypher"; then
  echo "    futureadvisor-cypher already exists — rebuilding to pick up latest rules"
  docker exec future-advisor-ollama ollama rm futureadvisor-cypher:latest 2>/dev/null || true
fi
docker cp Modelfile.dof future-advisor-ollama:/tmp/Modelfile.dof
docker exec future-advisor-ollama ollama create futureadvisor-cypher:latest -f /tmp/Modelfile.dof

echo
echo "Done."
docker compose ps
echo
echo "Open:  http://$(hostname -I | awk '{print $1}'):3080"
echo "       sign up, then pick 'Department of Finance Knowledge Graph' from the endpoint menu"
echo
echo "Agent health:   curl http://localhost:8001/health"
echo "Neo4j browser:  http://$(hostname -I | awk '{print $1}'):7474"
echo "Agent logs:     docker compose logs -f synthea-agent"
echo "UI logs:        docker compose logs -f librechat"
