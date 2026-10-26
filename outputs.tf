output "web_url" {
  description = "Public URL of the Next.js web app"
  value       = digitalocean_app.fa.live_url
}

output "api_url" {
  description = "Public URL of the NestJS GraphQL API"
  value       = "https://${var.project_name}-api.ondigitalocean.app/graphql"
}

output "registry_endpoint" {
  value = local.registry_endpoint
}

output "pg_host" {
  value = digitalocean_database_cluster.pg.host
}

output "pg_user" {
  value = digitalocean_database_user.fa.name
}

output "pg_password" {
  value     = digitalocean_database_user.fa.password
  sensitive = true
}

output "database_url_private" {
  description = "Postgres URI reachable from inside the DO VPC"
  value       = local.database_url
  sensitive   = true
}

output "database_url_public" {
  description = "Postgres URI reachable from your laptop (for one-off migrations)"
  value = format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    digitalocean_database_user.fa.name,
    digitalocean_database_user.fa.password,
    digitalocean_database_cluster.pg.host,
    digitalocean_database_cluster.pg.port,
    digitalocean_database_db.fa.name,
  )
  sensitive = true
}

output "redis_uri" {
  description = "Redis URI used by the apps — managed cluster if provisioned, else the internal sidecar"
  value       = local.redis_uri
  sensitive   = true
}
