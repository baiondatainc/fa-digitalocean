########################################
# Managed Postgres (TimescaleDB extension available on the managed service)
########################################
resource "digitalocean_database_cluster" "pg" {
  name       = "${var.project_name}-pg"
  engine     = "pg"
  version    = "16"
  size       = var.pg_size
  region     = var.region
  node_count = 1
  tags       = [var.project_name]
}

# Dedicated application role; the managed cluster already provides `doadmin`
# but that account should not be baked into app containers.
resource "random_password" "fa_db" {
  length  = 24
  special = false
}

resource "digitalocean_database_user" "fa" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "fa"
  # DO exposes `password` as a computed attribute per user; we store the
  # generated password so the connection string in locals/outputs is stable.

  # The DO provider v2.106 PUTs user_settings on every refresh and 400s when
  # it has nothing to send; this user has no settings to manage.
  lifecycle {
    ignore_changes = [settings]
  }
}

resource "digitalocean_database_db" "fa" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = "future_advisor"
}

# Lock the cluster down to App Platform + your office IP (optional). Fill the
# list via `office_ips` tfvar if you want IP allowlisting.
variable "office_ips" {
  type        = list(string)
  description = "Extra IPv4/CIDR entries allowed to reach the managed Postgres"
  default     = []
}

resource "digitalocean_database_firewall" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id

  dynamic "rule" {
    for_each = var.office_ips
    content {
      type  = "ip_addr"
      value = rule.value
    }
  }

  # App Platform workloads use type=app with the app id; wired below.
  rule {
    type  = "app"
    value = digitalocean_app.fa.id
  }
}

########################################
# Managed Redis (opt-in). Default is false — the App Platform spec runs
# redis:7-alpine as an internal sidecar service instead.
########################################
resource "digitalocean_database_cluster" "redis" {
  count = var.use_managed_redis ? 1 : 0

  name       = "${var.project_name}-redis"
  engine     = "redis"
  version    = "7"
  size       = var.redis_size
  region     = var.region
  node_count = 1
  tags       = [var.project_name]
}

resource "digitalocean_database_firewall" "redis" {
  count      = var.use_managed_redis ? 1 : 0
  cluster_id = digitalocean_database_cluster.redis[0].id

  rule {
    type  = "app"
    value = digitalocean_app.fa.id
  }
}

########################################
# Connection strings used by the app containers
########################################
locals {
  # The App Platform app sits in a different VPC than Managed DB private DNS;
  # use the public hostname (the firewall rule by app id already restricts access).
  pg_host = digitalocean_database_cluster.pg.host
  pg_port = digitalocean_database_cluster.pg.port
  # Managed Redis URI if provisioned; else talk to the internal App Platform
  # sidecar on its service name. App Platform resolves `redis` to the sidecar.
  redis_uri = var.use_managed_redis ? digitalocean_database_cluster.redis[0].private_uri : "redis://redis:6379/0"

  # NestJS + ingest + forecast all read DATABASE_URL. We point at the dedicated
  # `fa` user; the password is the one DO generated for digitalocean_database_user.fa.
  database_url = format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    digitalocean_database_user.fa.name,
    digitalocean_database_user.fa.password,
    local.pg_host,
    local.pg_port,
    digitalocean_database_db.fa.name,
  )
}
