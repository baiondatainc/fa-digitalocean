#!/usr/bin/env bash
# 01-prereqs.sh — run ONCE on the NEW GPU droplet, as root.
#
# Installs Docker, NVIDIA Container Toolkit (so Ollama can use the GPU), and doctl.
# Idempotent: safe to re-run.
#
# Prereq: the NVIDIA driver package for your GPU is already installed and
# `nvidia-smi` prints the device list. On a DigitalOcean GPU droplet this is
# pre-installed. On a bare Ubuntu box run `ubuntu-drivers autoinstall` first
# and reboot.
set -euo pipefail

echo "==> 1/5 Confirm GPU is visible"
if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "  ! nvidia-smi not found. Install the NVIDIA driver first (reboot after), then re-run."
    exit 2
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

echo
echo "==> 2/5 Install Docker (official)"
if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
else
    echo "  docker already installed ($(docker --version))"
fi

echo
echo "==> 3/5 Install NVIDIA Container Toolkit"
if ! docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
    distribution=$(. /etc/os-release; echo "$ID$VERSION_ID")
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update -qq
    apt-get install -y nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
fi
docker info 2>/dev/null | grep "Runtimes:" || echo "  ! nvidia runtime not registered; check logs"

echo
echo "==> 4/5 Quick GPU test"
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi \
    --query-gpu=name,memory.used,memory.total --format=csv,noheader \
  || { echo "  ! GPU test failed"; exit 3; }

echo
echo "==> 5/5 Install doctl"
if ! command -v doctl >/dev/null 2>&1; then
    snap install doctl
fi
doctl version

echo
echo "Done. Now run:"
echo "  doctl auth init                 # paste a DO PAT with Container Registry Read"
echo "  doctl registry login            # writes creds to ~/.docker/config.json"
echo "Then scp the migration bundle (see README) and run ./02-start.sh"
