variable "project_name" {
  type        = string
  description = "Short name used in resource names and tags"
  default     = "future-advisor"
}

variable "region" {
  type        = string
  description = "DO region slug (fra1 for Frankfurt residency)"
  default     = "fra1"
}

variable "registry_name" {
  type        = string
  description = "Container registry name — must already exist on the account; set to the name shown by `doctl registry get`."
  default     = "future-advisor"
}

variable "image_tag" {
  type        = string
  description = "Tag of the images to deploy (match the output of scripts/push-docker-do.sh)"
  default     = "latest"
}

variable "pg_size" {
  type        = string
  description = "Managed Postgres node size slug"
  default     = "db-s-1vcpu-1gb"
}

variable "redis_size" {
  type        = string
  description = "Managed Redis node size slug (unused when use_managed_redis = false)"
  default     = "db-s-1vcpu-1gb"
}

variable "use_managed_redis" {
  type        = bool
  description = "If true, provision a DO Managed Redis. If false, run redis:7-alpine as an internal App Platform service (cheaper, no persistence across restarts — fine for the fa.driver.updated channel)."
  default     = false
}

variable "llm_api_key" {
  type        = string
  description = "Anthropic (or compatible) key used by the forecast agent"
  sensitive   = true
  default     = ""
}

variable "jwt_secret" {
  type        = string
  description = "JWT signing secret for the NestJS API"
  sensitive   = true
  default     = ""
}
