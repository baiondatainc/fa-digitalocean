# The DO Container Registry is already created manually (one per account).
# We only need its name — the endpoint is deterministic
# (`registry.digitalocean.com/<name>`), so there's no need for a data lookup.
resource "digitalocean_container_registry_docker_credentials" "pull" {
  registry_name  = var.registry_name
  write          = false
  expiry_seconds = 3600 * 24 * 30 # 30 days
}

locals {
  registry_endpoint = "registry.digitalocean.com/${var.registry_name}"
}
