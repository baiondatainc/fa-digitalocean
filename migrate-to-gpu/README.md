# Migrate the full stack to a GPU box

Moves **both** the chatbot (`/opt/chatbot`) and the future-advisor app (`/opt/future-advisor` — web, api, forecast, ingest, Caddy, TimescaleDB) from the current droplet `168.144.133.124` to a new DO GPU droplet. Everything else gets pulled from the DO registry (`registry.digitalocean.com/future-advisor/*`) and Docker Hub — no image tarballs to ship.

**What's in this folder:**
| File | Where it runs | Purpose |
|---|---|---|
| `01-prereqs.sh` | NEW box | Installs Docker, NVIDIA Container Toolkit, doctl |
| `02-start.sh` | NEW box | Lays out configs, pulls images, brings up both stacks, restores Postgres, seeds Neo4j, creates the Ollama cypher model, creates the LibreChat admin user |
| `docker-compose.chatbot.yml` | reference | Fresh compose with **GPU reservation enabled** + a self-contained `ollama` service. Overwrite `/opt/chatbot/docker-compose.yml` with this after rsync. |

---

## 0. One-time on the OLD droplet — publish the patched web image

The current `future-advisor-prod-web-1` runs an image built locally (`future-advisor-web:ask-alpha-chat`, created by `docker commit` when we rewired Ask Rashid → LibreChat). That tag is **not** in any registry yet. Push it so the new box can pull it:

```bash
ssh root@168.144.133.124 '
  docker tag future-advisor-web:ask-alpha-chat registry.digitalocean.com/future-advisor/web:ask-alpha-chat
  docker push registry.digitalocean.com/future-advisor/web:ask-alpha-chat
'
```

Then update `/opt/future-advisor/docker-compose.prod.yml` on the OLD box (so when we rsync it to NEW box, it pulls the registry image, not a local one):

```bash
ssh root@168.144.133.124 '
  sed -i "s|image: future-advisor-web:ask-alpha-chat|image: registry.digitalocean.com/future-advisor/web:ask-alpha-chat|" /opt/future-advisor/docker-compose.prod.yml
  sed -i "/^    image: registry.digitalocean.com\/future-advisor\/web:ask-alpha-chat/a\    pull_policy: always" /opt/future-advisor/docker-compose.prod.yml   # replace "pull_policy: never"
'
```

> If you skip step 0 the new box will fail with "image not found" for the web service.

---

## 1. Provision the GPU droplet

In the DigitalOcean console (or via `doctl compute droplet create`), pick a GPU droplet. Smallest that fits our 4B-parameter Cypher model with 16 GB VRAM headroom:

| Slug | GPU | Hourly | Good for |
|---|---|---|---|
| `gpu-rtx4000adax1-20gb` | 1× RTX 4000 Ada 20 GB | ~$0.76 | Our 4B q4 model (plenty of headroom) |
| `gpu-rtx6000adax1-48gb` | 1× RTX 6000 Ada 48 GB | ~$1.57 | Room for 14B models |
| `gpu-h100x1-80gb` | 1× H100 80 GB | ~$3.39 | Overkill but fine |

Choose Ubuntu 24.04. Add your SSH key. Note the new IP (say `NEW_IP`).

---

## 2. Dump data on the OLD droplet

```bash
ssh root@168.144.133.124 bash -s <<'EOF'
  # Postgres dump (TimescaleDB inside the future-advisor stack)
  docker exec future-advisor-prod-timescaledb-1 \
    pg_dumpall -U postgres --clean --if-exists > /tmp/postgres.dump
  ls -lh /tmp/postgres.dump

  # Tar the two config trees (SMALL, no volumes)
  tar -czf /tmp/migrate-bundle.tar.gz \
      -C /opt \
      chatbot \
      future-advisor \
      --exclude='**/node_modules' \
      --exclude='**/*.log' \
      --exclude='**/.next/cache'
  ls -lh /tmp/migrate-bundle.tar.gz
EOF
```

If you want to migrate LibreChat users too (not strictly needed — `02-start.sh` recreates the admin):

```bash
ssh root@168.144.133.124 '
  docker exec fa-mongodb mongodump --archive=/tmp/librechat.archive --db=LibreChat
  docker cp fa-mongodb:/tmp/librechat.archive /tmp/librechat.archive
'
```

---

## 3. Ship files from OLD → NEW

From **your local box** (`baionserver`):

```bash
# a) pull the artifacts from old
scp -i ~/.ssh/id_ed25519 root@168.144.133.124:/tmp/postgres.dump        .
scp -i ~/.ssh/id_ed25519 root@168.144.133.124:/tmp/migrate-bundle.tar.gz .
# (optional) scp -i ~/.ssh/id_ed25519 root@168.144.133.124:/tmp/librechat.archive .

# b) push them + this migrate-to-gpu folder to the NEW box
scp -i ~/.ssh/id_ed25519 -r \
    /home/siva/work/codebase/alpha/digitalocean/migrate-to-gpu \
    root@NEW_IP:/root/

ssh -i ~/.ssh/id_ed25519 root@NEW_IP 'mkdir -p /opt/migrate-source'
scp -i ~/.ssh/id_ed25519 postgres.dump        root@NEW_IP:/opt/migrate-source/
scp -i ~/.ssh/id_ed25519 migrate-bundle.tar.gz root@NEW_IP:/opt/migrate-source/

ssh -i ~/.ssh/id_ed25519 root@NEW_IP '
  cd /opt/migrate-source
  tar -xzf migrate-bundle.tar.gz   # extracts chatbot/ and future-advisor/ here
  ls -la
'
```

Also ship your docker registry creds so NEW box can pull private images (alternative: `doctl registry login` on the new box):

```bash
scp -i ~/.ssh/id_ed25519 ~/.docker/config.json root@NEW_IP:/root/.docker/config.json
```

---

## 4. Run on the NEW box

```bash
ssh -i ~/.ssh/id_ed25519 root@NEW_IP
# — now in a shell on the new GPU box, as root —

cd /root/migrate-to-gpu
chmod +x 01-prereqs.sh 02-start.sh

# 4a. Install Docker + NVIDIA toolkit + doctl
./01-prereqs.sh

# 4b. (if you did NOT scp ~/.docker/config.json)
doctl auth init             # paste a DO PAT with Container Registry Read
doctl registry login

# 4c. Swap in the GPU-enabled chatbot compose BEFORE running 02-start.sh
#     (this is the key difference vs. the old droplet where Ollama was CPU-only)
cp docker-compose.chatbot.yml /opt/migrate-source/chatbot/docker-compose.yml

# 4d. Bring up everything
./02-start.sh
```

`02-start.sh` prints the final URLs and next step: update Caddy for NEW_IP.

---

## 5. Caddy + DNS

```bash
# Rewrite the Caddyfile hostnames from the old IP to the new one
sed -i 's/168.144.133.124/NEW_IP/g' /opt/future-advisor/Caddyfile
docker restart future-advisor-prod-proxy-1
```

After reload, Caddy auto-issues fresh Let's Encrypt certs for:
- `https://NEW_IP.nip.io`       → future-advisor web
- `https://chat.NEW_IP.nip.io`  → LibreChat

If you have a real domain, point an A record at `NEW_IP` and add a new site block in the Caddyfile (next to the existing `168.144.133.124.nip.io` one).

---

## 6. Verify

```bash
# On the NEW box
nvidia-smi                                                        # confirm GPU visible
docker exec fa-ollama ollama ps                                   # must say "PROCESSOR   100% GPU"
curl -s http://localhost:8001/health                              # {"status":"ok","neo4j":"connected"}
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:3080/  # HTTP 200
docker exec fa-neo4j cypher-shell -u neo4j -p "$(grep NEO4J_PASSWORD /opt/chatbot/.env | cut -d= -f2)" \
    "MATCH (n) RETURN count(n) AS nodes"   # ~135,034
```

First Cypher query on GPU: **~5-15 seconds** (vs 8 minutes on CPU). Later cached queries: **~1 second**.

---

## 7. Decommission the old droplet (when you're sure)

```bash
# On the old droplet
docker compose -f /opt/chatbot/docker-compose.yml down
docker compose -f /opt/future-advisor/docker-compose.prod.yml down
# Keep the droplet powered off for a week before destroying, in case of rollback.
```

---

## Troubleshooting

- **`docker pull` says unauthorized** — re-run `doctl registry login`, or `scp ~/.docker/config.json` from your workstation to `/root/.docker/`.
- **`nvidia-smi` not found inside a container** — NVIDIA Container Toolkit isn't registered. `nvidia-ctk runtime configure --runtime=docker && systemctl restart docker`.
- **`ollama ps` says `100% CPU`** — the GPU reservation isn't being honored. Check `docker info | grep Runtimes` lists `nvidia`, and that `docker-compose.yml` has the `deploy.resources.reservations.devices` block for the ollama service.
- **Postgres restore fails** — check the dump format: `file /opt/migrate-source/postgres.dump`. If it's "ASCII text" use `psql < dump`, if "PostgreSQL custom database dump" use `pg_restore` (02-start.sh tries both automatically).
- **Caddy says 403 on the new domain** — Let's Encrypt rate-limit; wait 1 hour and retry, or use the `--staging` ACME directory while testing.
- **LibreChat login "Unable to login"** — the user wasn't created or password mismatch. Rerun `02-start.sh`'s step 8 command directly.
