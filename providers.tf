terraform {
  required_version = ">= 1.6"
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.42"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

# The DigitalOcean provider reads DIGITALOCEAN_TOKEN from the environment by
# default. For CI/CD you can also set `do_token = "dop_v1_..."` in
# terraform.auto.tfvars and the provider will use that instead.
variable "do_token" {
  type        = string
  description = "DigitalOcean PAT. Optional if DIGITALOCEAN_TOKEN is exported."
  sensitive   = true
  default     = "dop_v1_8a0e4f82fecd6ac7becd028ca27b969c11198301c3f187da8072e4d4420960d7"
}

provider "digitalocean" {
  token = var.do_token != "" ? var.do_token : null
}
