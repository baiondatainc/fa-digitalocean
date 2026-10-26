#!/usr/bin/env bash
# One-time bootstrap: move terraform.tfstate from local disk into DO Spaces.
#
# Prereqs:
#   doctl auth init
#   You have a Spaces key + secret from https://cloud.digitalocean.com/account/api/spaces
#
# After this runs successfully, you can delete the local terraform.tfstate.*
# files and never commit them again.
set -euo pipefail

HERE=$(cd "$(dirname "$0")/.." && pwd)
cd "$HERE"

BUCKET="${BUCKET:-fa-tfstate}"
REGION="${REGION:-fra1}"

echo "==> ensuring Spaces bucket $BUCKET exists in $REGION"
if ! doctl spaces list --format Name --no-header 2>/dev/null | grep -qx "$BUCKET"; then
  doctl spaces create "$BUCKET" --region "$REGION"
else
  echo "    bucket already exists — reusing"
fi

echo
echo "==> Spaces access keys"
if [[ -z "${AWS_ACCESS_KEY_ID:-}" || -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
  cat <<MSG
Export your Spaces key + secret before continuing:

  export AWS_ACCESS_KEY_ID='DO...key...'
  export AWS_SECRET_ACCESS_KEY='...secret...'

Generate a key at:
  https://cloud.digitalocean.com/account/api/spaces

Then re-run this script.
MSG
  exit 1
fi
echo "    using key ${AWS_ACCESS_KEY_ID:0:4}********"

echo
echo "==> initialising Terraform with the s3 backend and migrating state"
# `-migrate-state` copies any existing local terraform.tfstate up to Spaces.
terraform init -migrate-state -input=false

echo
echo "==> cleanup"
if [[ -f terraform.tfstate ]]; then
  mv terraform.tfstate "terraform.tfstate.backup.$(date +%Y%m%d-%H%M%S)"
  echo "    local terraform.tfstate archived"
fi
if [[ -f terraform.tfstate.backup ]]; then
  rm -f terraform.tfstate.backup
fi

echo
echo "Done. State now lives at s3://$BUCKET/digitalocean/terraform.tfstate"
echo "Future runs:"
echo "  export AWS_ACCESS_KEY_ID=…"
echo "  export AWS_SECRET_ACCESS_KEY=…"
echo "  export DIGITALOCEAN_TOKEN=…"
echo "  terraform plan"
