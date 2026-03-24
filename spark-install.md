# NemoClaw on DGX Spark

> **WIP** — This page is actively being updated as we work through Spark installs. Expect changes.

## Quick Start

```bash
# Clone and install
git clone https://github.com/darbotlabs/NemoClaw.git
cd NemoClaw
sudo npm install -g .

# Spark-specific setup (configures Docker for cgroup v2, then runs normal setup)
nemoclaw setup-spark
```

That's it. `setup-spark` handles everything below automatically, including GPU passthrough.

## What's Different on Spark

DGX Spark ships **Ubuntu 24.04 + Docker 28.x** but no k8s/k3s. OpenShell embeds k3s inside a Docker container, which hits two problems on Spark:

### 1. Docker permissions

```
Error in the hyper legacy client: client error (Connect)
  Permission denied (os error 13)
```

**Cause**: Your user isn't in the `docker` group.
**Fix**: `setup-spark` runs `usermod -aG docker $USER`. You may need to log out and back in (or `newgrp docker`) for it to take effect.

### 2. cgroup v2 incompatibility

```
K8s namespace not ready
openat2 /sys/fs/cgroup/kubepods/pids.max: no
Failed to start ContainerManager: failed to initialize top level QOS containers
```

**Cause**: Spark runs cgroup v2 (Ubuntu 24.04 default). OpenShell's gateway container starts k3s, which tries to create cgroup v1-style paths that don't exist. The fix is `--cgroupns=host` on the container, but OpenShell doesn't expose that flag.

**Fix**: `setup-spark` sets `"default-cgroupns-mode": "host"` in `/etc/docker/daemon.json` and restarts Docker. This makes all containers use the host cgroup namespace, which is what k3s needs.

### 3. GPU passthrough

Spark ships with the NVIDIA Container Toolkit pre-installed, but a fresh install may not have the nvidia runtime registered in Docker's `daemon.json` or have CDI device specs in `/etc/cdi/` (the persistent location Docker resolves).

**Fix**: `setup-spark` runs `nvidia-ctk runtime configure --runtime=docker` to register the nvidia runtime and `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` to write persistent CDI specs. Then `nemoclaw onboard` detects both `nvidia-smi` and the presence of `/etc/cdi/nvidia.yaml`, and automatically passes `--gpu` to `openshell gateway start` and `openshell sandbox create`, which exposes the GPU inside the NemoClaw sandbox pod. GPU passthrough is skipped if the CDI specs are absent (i.e., `setup-spark` has not been run).

## Prerequisites

These should already be on your Spark:

- **Docker** (pre-installed, v28.x)
- **Node.js 22** — if not installed:
  ```bash
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt-get install -y nodejs
  ```
- **OpenShell CLI**:
  ```bash
  ARCH=$(uname -m)  # aarch64 on Spark
  curl -fsSL "https://github.com/NVIDIA/OpenShell/releases/latest/download/openshell-linux-${ARCH}" -o /usr/local/bin/openshell
  chmod +x /usr/local/bin/openshell
  ```
- **NVIDIA Container Toolkit** (pre-installed on Spark, but verify):
  ```bash
  nvidia-ctk --version   # should print version
  nvidia-smi             # should list your GPU
  ```
- **NVIDIA API Key** from [build.nvidia.com](https://build.nvidia.com) — prompted on first run

## Manual Setup (if setup-spark doesn't work)

### Fix Docker cgroup namespace

```bash
# Check if you're on cgroup v2
stat -fc %T /sys/fs/cgroup/
# Expected: cgroup2fs

# Add cgroupns=host to Docker daemon config
sudo python3 -c "
import json, os
path = '/etc/docker/daemon.json'
d = json.load(open(path)) if os.path.exists(path) else {}
d['default-cgroupns-mode'] = 'host'
json.dump(d, open(path, 'w'), indent=2)
"

# Restart Docker
sudo systemctl restart docker
```

### Fix Docker permissions

```bash
sudo usermod -aG docker $USER
newgrp docker  # or log out and back in
```

### Enable GPU passthrough

```bash
# Register NVIDIA runtime with Docker and write persistent CDI specs
sudo nvidia-ctk runtime configure --runtime=docker
sudo mkdir -p /etc/cdi
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo systemctl restart docker

# Verify
docker info | grep -i nvidia   # should show nvidia in Runtimes
nvidia-ctk cdi list            # should list nvidia.com/gpu=all
```

```bash
nemoclaw onboard
```

## Known Issues

| Issue | Status | Workaround |
|-------|--------|------------|
| cgroup v2 kills k3s in Docker | Fixed in `setup-spark` | `daemon.json` cgroupns=host |
| Docker permission denied | Fixed in `setup-spark` | `usermod -aG docker` |
| CoreDNS CrashLoop after setup | Fixed in `fix-coredns.sh` | Uses container gateway IP, not 127.0.0.11 |
| Image pull failure (k3s can't find built image) | OpenShell bug | `openshell gateway destroy && openshell gateway start`, re-run setup |
| GPU passthrough | Fixed in `setup-spark` | `nvidia-ctk runtime configure` + CDI generate |

```bash
# Check GPU is visible inside the sandbox
openshell sandbox connect nemoclaw
# Inside sandbox:
nvidia-smi   # should show your Spark GPU
```

## Verifying Your Install

```bash
# Check sandbox is running
openshell sandbox list
# Should show: nemoclaw  Ready

# Test the agent
openshell sandbox connect nemoclaw
# Inside sandbox:
nemoclaw-start openclaw agent --agent main --local -m 'hello' --session-id test

# Monitor network egress (separate terminal)
openshell term
```

## Architecture Notes

```
DGX Spark (Ubuntu 24.04, cgroup v2)
  ├── NVIDIA GB10 GPU (nvidia-container-toolkit, CDI /etc/cdi/nvidia.yaml)
  └── Docker (28.x, cgroupns=host, nvidia runtime registered)
       └── OpenShell gateway container  [--gpu → --device nvidia.com/gpu=all]
            └── k3s (embedded)
                 └── nemoclaw sandbox pod
                      ├── OpenClaw agent + NemoClaw plugin
                      └── /dev/nvidia0  (GPU passthrough via CDI)
```
