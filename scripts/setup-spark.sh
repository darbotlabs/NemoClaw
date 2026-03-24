#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# NemoClaw setup for DGX Spark devices.
#
# Spark ships Ubuntu 24.04 (cgroup v2) + Docker 28.x but no k3s.
# OpenShell's gateway starts k3s inside a Docker container, which
# needs cgroup host namespace access. This script configures Docker
# for that. Safe to re-run on subsequent nodes — all steps are idempotent.
#
# Usage:
#   sudo nemoclaw setup-spark
#   # or directly:
#   sudo bash scripts/setup-spark.sh
#
# Non-interactive / multi-node deployment:
#   NVIDIA_API_KEY=<key> sudo -E nemoclaw setup-spark
#   Then: NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_PROVIDER=ollama \
#         NEMOCLAW_SANDBOX_NAME=my-assistant nemoclaw onboard
#
# What it does:
#   1. Adds current user to docker group (avoids sudo for everything else)
#   2. Configures Docker daemon for cgroupns=host (k3s-in-Docker on cgroup v2)
#   3. Configures NVIDIA Container Toolkit for GPU passthrough (if GPU present)
#   4. Restarts Docker (only if config changed)
#   5. Verifies GPU passthrough works end-to-end

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${GREEN}>>>${NC} $1"; }
warn() { echo -e "${YELLOW}>>>${NC} $1"; }
success() { echo -e "${GREEN}  ✓${NC} $1"; }
fail() {
  echo -e "${RED}>>>${NC} $1"
  exit 1
}

# ── Pre-flight checks ─────────────────────────────────────────────

if [ "$(uname -s)" != "Linux" ]; then
  fail "This script is for DGX Spark (Linux). Use 'nemoclaw setup' for macOS."
fi

if [ "$(id -u)" -ne 0 ]; then
  fail "Must run as root: sudo nemoclaw setup-spark"
fi

# Detect the real user (not root) for docker group add
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "")}"
if [ -z "$REAL_USER" ]; then
  warn "Could not detect non-root user. Docker group will not be configured."
fi

command -v docker >/dev/null || fail "Docker not found. DGX Spark should have Docker pre-installed."
command -v python3 >/dev/null || fail "python3 not found. Required for daemon.json manipulation."

# ── 1. Docker group ───────────────────────────────────────────────

if [ -n "$REAL_USER" ]; then
  if id -nG "$REAL_USER" | grep -qw docker; then
    info "User '$REAL_USER' already in docker group"
  else
    info "Adding '$REAL_USER' to docker group..."
    usermod -aG docker "$REAL_USER"
    info "Added. Group will take effect on next login (or use 'newgrp docker')."
  fi
fi

# ── 2. Docker cgroup namespace ────────────────────────────────────
#
# Spark runs cgroup v2 (Ubuntu 24.04). OpenShell's gateway embeds
# k3s in a Docker container, which needs --cgroupns=host to manage
# cgroup hierarchies. Without this, kubelet fails with:
#   "openat2 /sys/fs/cgroup/kubepods/pids.max: no"
#
# Setting default-cgroupns-mode=host in daemon.json makes all
# containers use the host cgroup namespace. This is safe — it's
# the Docker default on cgroup v1 hosts anyway.

DAEMON_JSON="/etc/docker/daemon.json"
NEEDS_RESTART=false

if [ -f "$DAEMON_JSON" ]; then
  # Check if already configured
  if grep -q '"default-cgroupns-mode"' "$DAEMON_JSON" 2>/dev/null; then
    CURRENT_MODE=$(python3 -c "import json; print(json.load(open('$DAEMON_JSON')).get('default-cgroupns-mode',''))" 2>/dev/null || echo "")
    if [ "$CURRENT_MODE" = "host" ]; then
      info "Docker daemon already configured for cgroupns=host"
    else
      info "Updating Docker daemon cgroupns mode to 'host'..."
      python3 -c "
import json
with open('$DAEMON_JSON') as f:
    d = json.load(f)
d['default-cgroupns-mode'] = 'host'
with open('$DAEMON_JSON', 'w') as f:
    json.dump(d, f, indent=2)
"
      NEEDS_RESTART=true
    fi
  else
    info "Adding cgroupns=host to Docker daemon config..."
    python3 -c "
import json
try:
    with open('$DAEMON_JSON') as f:
        d = json.load(f)
except:
    d = {}
d['default-cgroupns-mode'] = 'host'
with open('$DAEMON_JSON', 'w') as f:
    json.dump(d, f, indent=2)
"
    NEEDS_RESTART=true
  fi
else
  info "Creating Docker daemon config with cgroupns=host..."
  mkdir -p "$(dirname "$DAEMON_JSON")"
  echo '{ "default-cgroupns-mode": "host" }' >"$DAEMON_JSON"
  NEEDS_RESTART=true
fi

# ── 3. NVIDIA Container Toolkit (GPU passthrough) ────────────────
#
# Spark ships with the NVIDIA Container Toolkit pre-installed.
# Register the nvidia runtime with Docker and generate persistent CDI
# device specs under /etc/cdi so that `openshell gateway start --gpu`
# can expose the GPU inside the NemoClaw sandbox pod.
# The specs in /var/run/cdi are volatile (tmpfs); /etc/cdi survives
# reboots and is the preferred location for Docker's CDI resolver.
# This step is always run so stale specs from a previous install or
# hardware change are refreshed automatically.

GPU_READY=false

if command -v nvidia-smi >/dev/null 2>&1; then
  if command -v nvidia-ctk >/dev/null 2>&1; then
    # Register nvidia runtime in daemon.json (idempotent)
    if python3 -c "import json,sys; d=json.load(open('$DAEMON_JSON')); sys.exit(0 if 'nvidia' in d.get('runtimes',{}) else 1)" 2>/dev/null; then
      info "NVIDIA runtime already registered in Docker daemon"
    else
      info "Registering NVIDIA runtime in Docker daemon..."
      if ! nvidia-ctk runtime configure --runtime=docker 2>&1; then
        fail "nvidia-ctk runtime configure failed — check NVIDIA Container Toolkit installation."
      fi
      NEEDS_RESTART=true
    fi

    # Always regenerate CDI device specs to /etc/cdi (persistent across reboots).
    # Regenerating ensures specs match current hardware (important after re-imaging).
    info "Generating CDI device specs..."
    mkdir -p /etc/cdi
    CDI_OUTPUT=$(nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>&1)
    CDI_EXIT=$?
    if [ $CDI_EXIT -ne 0 ]; then
      warn "nvidia-ctk cdi generate failed (exit $CDI_EXIT): $CDI_OUTPUT"
      warn "GPU passthrough may not work. Check nvidia-ctk and driver state."
    elif [ ! -s /etc/cdi/nvidia.yaml ]; then
      warn "CDI spec file was created but is empty — GPU passthrough may not work."
    else
      success "CDI specs written to /etc/cdi/nvidia.yaml"
      GPU_READY=true
    fi
  else
    warn "nvidia-ctk not found. GPU passthrough will not work."
    warn "Install NVIDIA Container Toolkit: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html"
  fi
else
  info "No NVIDIA GPU detected — skipping GPU configuration."
fi

# ── 4. Restart Docker if needed ───────────────────────────────────

if [ "$NEEDS_RESTART" = true ]; then
  if docker ps -q 2>/dev/null | grep -q .; then
    warn "Docker restart required. Running containers will be temporarily stopped."
  fi
  info "Restarting Docker daemon..."
  systemctl restart docker
  # Wait for Docker to be ready
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if docker info >/dev/null 2>&1; then
      break
    fi
    [ "$i" -eq 10 ] && fail "Docker didn't come back after restart. Check 'systemctl status docker'."
    sleep 2
  done
  success "Docker restarted"
fi

# ── 5. Verify GPU passthrough (post-restart) ─────────────────────

if [ "$GPU_READY" = true ]; then
  info "Verifying GPU passthrough inside Docker..."
  # Pull a minimal CUDA image for the verification (uses local cache if present)
  VERIFY_IMAGE="nvcr.io/nvidia/cuda:12.6.3-base-ubuntu22.04"
  if docker run --rm --device nvidia.com/gpu=all "$VERIFY_IMAGE" nvidia-smi -L >/dev/null 2>&1; then
    success "GPU visible inside Docker containers"
  else
    # Non-fatal — CDI may still work; warn and let nemoclaw onboard confirm
    warn "GPU passthrough verification failed inside Docker."
    warn "  Try manually: docker run --rm --device nvidia.com/gpu=all $VERIFY_IMAGE nvidia-smi"
    warn "  If it works after 'newgrp docker' or re-login, it was a permissions issue."
  fi
fi

# ── 6. Done ──────────────────────────────────────────────────────

echo ""
info "DGX Spark setup complete."
echo ""
info "Summary:"
if [ -n "$REAL_USER" ]; then
  success "User '$REAL_USER' is in the docker group"
fi
success "Docker daemon configured for cgroupns=host (cgroup v2 compatibility)"
if [ "$GPU_READY" = true ]; then
  success "GPU passthrough configured (CDI specs at /etc/cdi/nvidia.yaml)"
else
  warn "GPU passthrough was NOT configured (no GPU or nvidia-ctk issue)"
fi
echo ""
info "Next: run 'nemoclaw onboard' to create your sandbox."
echo ""
info "For non-interactive / multi-node deployment:"
info "  NEMOCLAW_NON_INTERACTIVE=1 \\"
info "  NEMOCLAW_PROVIDER=ollama \\"
info "  NEMOCLAW_SANDBOX_NAME=\$(hostname -s) \\"
info "  nemoclaw onboard"
echo ""
if id -nG "${REAL_USER:-root}" 2>/dev/null | grep -qw docker; then
  true
else
  warn "You may need to log out and back in (or run 'newgrp docker') before running nemoclaw onboard."
fi
