#!/usr/bin/env bash
# 02-start.sh — run on the NEW GPU droplet, as root, AFTER 01-prereqs.sh.
#
# Expects /opt/migrate-source/ to exist, populated by `scp` from the OLD droplet:
#   /opt/migrate-source/chatbot/          (from /opt/chatbot on old box)
#   /opt/migrate-source/future-advisor/   (from /opt/future-advisor on old box)
#   /opt/migrate-source/postgres.dump     (pg_dump output from old box; see README)
#
# This script:
#   1. unpacks configs into /opt/{chatbot,future-advisor}
#   2. docker compose pull for both stacks
#   3. brings them up
#   4. restores Postgres (future-advisor stack's TimescaleDB)
#   5. seeds Neo4j from the bundled CSV export
#   6. creates the futureadvisor-cypher Ollama model (now running on GPU)
#   7. creates the LibreChat admin user
#   8. prints next steps for Caddy / DNS
set -euo pipefail

SRC=/opt/migrate-source
test -d "$SRC/chatbot" || { echo "missing $SRC/chatbot — scp it from old droplet (see README)"; exit 2; }
test -d "$SRC/future-advisor" || { echo "missing $SRC/future-advisor"; exit 2; }
test -f "$SRC/postgres.dump" || echo "WARN: $SRC/postgres.dump not present — Postgres will start empty"

echo "==> 1/8 Lay out configs"
mkdir -p /opt/chatbot /opt/future-advisor
rsync -a --delete "$SRC/chatbot/"         /opt/chatbot/
rsync -a --delete "$SRC/future-advisor/"  /opt/future-advisor/

echo
echo "==> 2/8 Enable GPU on Ollama (this file comes from the bundle but double-check)"
# docker-compose.yml in the bundle already has the GPU reservations enabled.
grep -q "driver: nvidia" /opt/chatbot/docker-compose.yml \
    && echo "  GPU reservation present" \
    || echo "  ! no GPU block found in chatbot/docker-compose.yml — Ollama will run on CPU"

echo
echo "==> 3/8 Pull all images from DO registry + Docker Hub"
cd /opt/future-advisor && docker compose -f docker-compose.prod.yml pull
cd /opt/chatbot        && docker compose pull

echo
echo "==> 4/8 Bring up future-advisor stack first (Postgres, Caddy, web, api, …)"
cd /opt/future-advisor
docker compose -f docker-compose.prod.yml up -d
echo "  waiting for TimescaleDB to be ready (up to 2 min) …"
for i in {1..24}; do
    docker exec future-advisor-prod-timescaledb-1 pg_isready -U postgres -q && break
    sleep 5
done
pg_isready -h 127.0.0.1 -p 5432 -U postgres -q 2>/dev/null || true

echo
echo "==> 5/8 Restore Postgres dump (if provided)"
if [[ -f "$SRC/postgres.dump" ]]; then
    PG_USER="${PG_USER:-postgres}"
    PG_DB="${PG_DB:-postgres}"
    echo "  restoring $SRC/postgres.dump into $PG_DB as $PG_USER …"
    docker cp "$SRC/postgres.dump" future-advisor-prod-timescaledb-1:/tmp/postgres.dump
    # pg_restore handles custom format; psql for plain SQL — try pg_restore first
    docker exec future-advisor-prod-timescaledb-1 \
        pg_restore --clean --if-exists --no-owner --no-privileges \
                   -U "$PG_USER" -d "$PG_DB" /tmp/postgres.dump 2>&1 | tail -20 \
      || docker exec -i future-advisor-prod-timescaledb-1 \
           psql -U "$PG_USER" -d "$PG_DB" < "$SRC/postgres.dump" 2>&1 | tail -20
else
    echo "  no dump — skipping"
fi

echo
echo "==> 6/8 Bring up chatbot stack (Neo4j, Mongo, Meili, Ollama, synthea-agent, LibreChat)"
cd /opt/chatbot
docker compose up -d
echo "  waiting for Neo4j to be healthy …"
NEO4J_PASSWORD=$(grep ^NEO4J_PASSWORD .env | cut -d= -f2)
for i in {1..24}; do
    docker exec fa-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" "RETURN 1" >/dev/null 2>&1 && break
    sleep 5
done

echo "  applying Neo4j constraints"
docker exec -i fa-neo4j cypher-shell -u neo4j -p "$NEO4J_PASSWORD" -f /import/schema.cypher || true

echo "  loading the graph (reuses the agent container's python + neo4j driver)"
# The /opt/chatbot/neo4j_export was rsynced above. pg_to_neo4j.py is in /opt/chatbot/.
docker cp /opt/chatbot/pg_to_neo4j.py fa-synthea-agent:/tmp/pg_to_neo4j.py
docker cp /opt/chatbot/neo4j_export   fa-synthea-agent:/tmp/neo4j_export
docker exec -e NEO4J_PASSWORD="$NEO4J_PASSWORD" fa-synthea-agent \
    /app/.venv/bin/python /tmp/pg_to_neo4j.py load \
    --out /tmp/neo4j_export --neo4j bolt://neo4j:7687 \
    --user neo4j --password "$NEO4J_PASSWORD" --batch 5000 2>&1 | tail -10

echo
echo "==> 7/8 Create the futureadvisor-cypher Ollama model (now on GPU!)"
# Ollama in the chatbot stack is the local `fa-ollama` service if you included one,
# otherwise reuse the existing future-advisor-ollama container.
OLLAMA=fa-ollama
docker ps --format '{{.Names}}' | grep -q "^$OLLAMA\$" || OLLAMA=future-advisor-ollama
docker cp /opt/chatbot/Modelfile.dof $OLLAMA:/tmp/Modelfile.dof
docker exec $OLLAMA ollama rm futureadvisor-cypher:latest 2>/dev/null || true
docker exec $OLLAMA ollama create futureadvisor-cypher:latest -f /tmp/Modelfile.dof

echo
echo "==> 8/8 Create LibreChat admin user"
LIBRECHAT_EMAIL="${LIBRECHAT_EMAIL:-sivacit@gmail.com}"
LIBRECHAT_NAME="${LIBRECHAT_NAME:-Hamza Al Rayahnah}"
LIBRECHAT_USER="${LIBRECHAT_USER:-siva}"
LIBRECHAT_PASS="${LIBRECHAT_PASS:-LM0JEBL58EUDVJHHYLM0JEBL58EUDVJHHY}"
docker exec fa-librechat node /app/config/create-user.js \
    "$LIBRECHAT_EMAIL" "$LIBRECHAT_NAME" "$LIBRECHAT_USER" "$LIBRECHAT_PASS" \
    --email-verified=true 2>&1 | tail -3

echo
echo "────── Done. Next steps ──────"
IP=$(hostname -I | awk '{print $1}')
echo "1. Update Caddyfile for this box's IP (replace '168.144.133.124' with '$IP'):"
echo "     sed -i 's/168.144.133.124/$IP/g' /opt/future-advisor/Caddyfile"
echo "     docker restart future-advisor-prod-proxy-1"
echo
echo "2. Point DNS (if you have a real domain) OR use nip.io:"
echo "     Chatbot:  https://chat.$IP.nip.io"
echo "     Main app: https://$IP.nip.io"
echo
echo "3. Agent health:   curl http://localhost:8001/health"
echo "   Neo4j browser:  http://$IP:7474"
echo "   LibreChat UI:   http://$IP:3080"
