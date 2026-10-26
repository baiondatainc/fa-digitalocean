# Future Advisor — DigitalOcean Terraform

Provisions the production stack on DigitalOcean:
- Managed Postgres 16 (TimescaleDB extension) with a dedicated `fa` role
- Managed Redis 7 (used for the `fa.driver.updated` channel and Celery beat)
- Container Registry (expected to already exist — one per DO account)
- App Platform app with 4 services (web, api, forecast-py, forecast-agent) + 1 worker (ingest-worker) + 1 scheduled job (forecast-cycle)

The Docker images themselves are built and pushed by
`future-advisor/scripts/push-docker-do.sh`.

## Prereqs

```bash
sudo snap install doctl                      # or brew install doctl
sudo snap connect doctl:dot-docker           # if Docker config errors
doctl auth init                              # paste PAT from https://cloud.digitalocean.com/account/api/tokens
doctl registry login                         # pulls creds into ~/.docker/config.json

# One-time registry — if not already created
doctl registry create future-advisor --subscription-tier basic
doctl registry get                           # confirm name used below
```

## Build and push images first

```bash
cd ../future-advisor
./scripts/push-docker-do.sh                  # tags images with current git SHA + :latest
```

## Apply the stack

```bash
cd ../digitalocean                        # this folder
cp terraform.auto.tfvars.example terraform.auto.tfvars
$EDITOR terraform.auto.tfvars                # fill in llm_api_key, jwt_secret, image_tag

export DIGITALOCEAN_TOKEN=dop_v1_...         # same PAT as doctl
terraform init
terraform plan
terraform apply
```

Grab the connection string Terraform printed:
```bash
terraform output -raw database_url_public
```

Apply migrations against the managed Postgres (first deploy only):
```bash
cd ../future-advisor
export DATABASE_URL=$(cd ../digitalocean && terraform output -raw database_url_public)
psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
psql "$DATABASE_URL" -c "CREATE EXTENSION IF NOT EXISTS timescaledb;"
make migrate-deploy
make apply-agent-sql
```

Public URLs:
```bash
cd ../digitalocean
terraform output web_url
terraform output api_url
```

## Rolling a new image

```bash
cd ../future-advisor
TAG=$(git rev-parse --short HEAD) ./scripts/push-docker-do.sh

cd ../digitalocean
terraform apply -var "image_tag=$TAG"
```

App Platform does a zero-downtime rolling deploy.

## Teardown

```bash
terraform destroy
```

The container registry is **not** destroyed (it's a `data` source) — delete it manually if needed:
```bash
doctl registry delete
```

## Remote state (recommended before any production use)

The Terraform state file stores plaintext secrets (JWT, DB password, LLM key).
Move it off your laptop and into DO Spaces so it's encrypted at rest and
shared across machines:

```bash
# One-time bootstrap. See scripts/bootstrap-remote-state.sh.
# Generate Spaces keys at https://cloud.digitalocean.com/account/api/spaces
export AWS_ACCESS_KEY_ID='DO...key...'
export AWS_SECRET_ACCESS_KEY='...secret...'
./scripts/bootstrap-remote-state.sh
```

The script creates the Spaces bucket `fa-tfstate` (fra1), copies any existing
state up, archives the local file, and leaves you ready to run plain
`terraform plan/apply` on any machine with the same env vars.

Future runs:
```bash
export AWS_ACCESS_KEY_ID=…
export AWS_SECRET_ACCESS_KEY=…
export DIGITALOCEAN_TOKEN=…
terraform plan
terraform apply
```

## Files

| File | Role |
|---|---|
| `providers.tf` | Terraform + provider setup |
| `backend.tf` | Remote state in DO Spaces |
| `variables.tf` | All inputs with defaults |
| `registry.tf` | Reference the DO container registry + pull creds |
| `database.tf` | Managed Postgres + Redis + firewall rules |
| `app.tf` | App Platform spec (web, api, forecast-agent, forecast-py, ingest-worker, forecast-cycle job) |
| `outputs.tf` | URLs + connection strings |
| `scripts/bootstrap-remote-state.sh` | One-time move of state into DO Spaces |
