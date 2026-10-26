# App Platform definition. One app with:
#   - web  (Next.js, public HTTP)
#   - api  (NestJS GraphQL, public HTTP)
#   - forecast-agent (FastAPI, internal only — talks to Postgres + Redis)
#   - forecast-py    (heavy python work, internal)
#   - ingest-worker  (background worker)
#   - forecast-cycle (pre-deploy job)
#
# Images come from the DO Container Registry under /<name>:<tag>. Push them
# first with scripts/push-docker-do.sh.
resource "digitalocean_app" "fa" {
  spec {
    name   = var.project_name
    region = var.region

    # ---------------- public ingress ----------------
    # Routes incoming HTTPS traffic to services. Order matters: more specific
    # paths must come first because App Platform matches top-down.
    ingress {
      rule {
        component {
          name                 = "api"
          preserve_path_prefix = true
        }
        match {
          path {
            prefix = "/graphql"
          }
        }
      }
      rule {
        component {
          name = "web"
        }
        match {
          path {
            prefix = "/"
          }
        }
      }
    }

    # ---------------- redis sidecar (internal, no persistence) ----------------
    # Only created when the managed Redis is turned off (var.use_managed_redis).
    # App Platform resolves `redis` as the service DNS inside the VPC.
    dynamic "service" {
      for_each = var.use_managed_redis ? [] : [1]
      content {
        name               = "redis"
        instance_count     = 1
        instance_size_slug = "basic-xxs"
        internal_ports     = [6379]

        image {
          registry_type = "DOCKER_HUB"
          registry      = "library"
          repository    = "redis"
          tag           = "7-alpine"
        }

        run_command = "redis-server --save '' --appendonly no"
      }
    }

    # ---------------- public web (Next.js) ----------------
    service {
      name               = "web"
      instance_count     = 1
      instance_size_slug = "basic-xxs"
      http_port          = 3000

      image {
        registry_type = "DOCR"
        repository    = "web"
        tag           = var.image_tag
      }

      env {
        key   = "NODE_ENV"
        value = "production"
      }
      env {
        key = "NEXT_PUBLIC_GRAPHQL_URL"
        # Same-origin via ingress; the browser resolves this against
        # window.location.origin.
        value = "/graphql"
      }
    }

    # ---------------- public API (NestJS GraphQL) ----------------
    service {
      name               = "api"
      instance_count     = 1
      instance_size_slug = "basic-xs"
      http_port          = 4000

      image {
        registry_type = "DOCR"
        repository    = "api"
        tag           = var.image_tag
      }

      env {
        key   = "NODE_ENV"
        value = "production"
      }
      env {
        key   = "API_PORT"
        value = "4000"
      }
      env {
        key   = "DATABASE_URL"
        value = local.database_url
        type  = "SECRET"
      }
      env {
        key   = "REDIS_URL"
        value = local.redis_uri
        type  = "SECRET"
      }
      env {
        key   = "JWT_SECRET"
        value = var.jwt_secret
        type  = "SECRET"
      }
      env {
        key   = "FORECAST_SERVICE_URL"
        value = "http://forecast-py:8000"
      }
      env {
        key   = "AGENT_API_URL"
        value = "http://forecast-agent:8020"
      }
      env {
        key   = "AGENT_API_TOKEN"
        value = var.jwt_secret
        type  = "SECRET"
      }
      # The API env schema also demands these — give deploy-safe placeholders
      # so startup doesn't fail. Features that need them (Neo4j graph, MinIO
      # file storage) will no-op gracefully.
      env {
        key   = "NEO4J_PASSWORD"
        value = "unused"
        type  = "SECRET"
      }
      env {
        key   = "MINIO_ACCESS_KEY"
        value = "unused"
        type  = "SECRET"
      }
      env {
        key   = "MINIO_SECRET_KEY"
        value = "unused"
        type  = "SECRET"
      }
    }

    # ---------------- forecast-agent (FastAPI, internal) ----------------
    service {
      name               = "forecast-agent"
      instance_count     = 1
      instance_size_slug = "basic-s"
      internal_ports     = [8020]

      # Default health check hits "/" which fa-agent doesn't expose; it only
      # has an unauthenticated /health.
      health_check {
        http_path             = "/health"
        port                  = 8020
        initial_delay_seconds = 30
        period_seconds        = 30
        timeout_seconds       = 5
        failure_threshold     = 5
      }

      image {
        registry_type = "DOCR"
        repository    = "forecast-agent"
        tag           = var.image_tag
      }

      run_command = "fa-agent serve-api"

      env {
        key   = "AGENT_DATABASE_URL_RO"
        value = local.database_url
        type  = "SECRET"
      }
      env {
        key   = "AGENT_DATABASE_URL_RW"
        value = local.database_url
        type  = "SECRET"
      }
      env {
        key   = "REDIS_URL"
        value = local.redis_uri
        type  = "SECRET"
      }
      env {
        key   = "AGENT_API_TOKEN"
        value = var.jwt_secret
        type  = "SECRET"
      }
      env {
        key   = "LLM_API_KEY"
        value = var.llm_api_key
        type  = "SECRET"
      }
      env {
        key   = "AGENT_ENVIRONMENTS"
        value = "dubai"
      }
    }

    # ---------------- forecast-py (heavy python work) ----------------
    service {
      name               = "forecast-py"
      instance_count     = 1
      instance_size_slug = "basic-xs"
      internal_ports     = [8000]

      image {
        registry_type = "DOCR"
        repository    = "forecast-py"
        tag           = var.image_tag
      }

      env {
        key   = "DATABASE_URL"
        value = local.database_url
        type  = "SECRET"
      }
    }

    # ---------------- ingest-worker (long-running puller) ----------------
    worker {
      name               = "ingest-worker"
      instance_count     = 1
      instance_size_slug = "basic-xs"

      image {
        registry_type = "DOCR"
        repository    = "ingest-worker"
        tag           = var.image_tag
      }

      env {
        key   = "DATABASE_URL"
        value = local.database_url
        type  = "SECRET"
      }
      env {
        key   = "REDIS_URL"
        value = local.redis_uri
        type  = "SECRET"
      }
    }

    # NOTE: an initial forecast cycle job used to run here as PRE_DEPLOY, but
    # it required migrations to be applied first. Run cycles on-demand via
    # the /agent/dubai/cycle endpoint instead, or add a POST_DEPLOY job once
    # migrations are stable.
  }
}
