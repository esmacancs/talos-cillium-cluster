#!/usr/bin/env bash
set -euo pipefail

# ─── Local registry mirror for Talos + Cilium image cache ──────────────────
# Runs three Docker registry:2 pull-through proxies on the host so that
# Talos VMs pull cached images instead of hitting the internet every time.

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

MIRROR_DIR="${MIRROR_DIR:-/var/lib/registry-mirror}"
HOST_IP="${HOST_IP:-192.168.121.1}"

# Proxy registries: name -> port -> upstream
declare -A PORTS
PORTS[ghcr.io]=5001
PORTS[registry.k8s.io]=5002
PORTS[quay.io]=5003

info "Setting up local registry mirrors on $HOST_IP ..."
mkdir -p "$MIRROR_DIR"

for registry in "${!PORTS[@]}"; do
  port="${PORTS[$registry]}"
  name="mirror-${registry//./-}"
  container_name="registry-mirror-$name"
  storage="$MIRROR_DIR/$name"

  mkdir -p "$storage"

  if docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    info "Registry mirror for $registry already running on port $port."
    continue
  fi

  info "Starting registry mirror for $registry on port $port (upstream: $registry) ..."
  docker run -d --restart=always \
    --name "$container_name" \
    -p "$port:5000" \
    -e REGISTRY_PROXY_REMOTEURL="https://${registry}" \
    -e REGISTRY_STORAGE_DELETE_ENABLED=true \
    -v "$storage:/var/lib/registry" \
    registry:2

  # Give it a moment to start
  sleep 2
  if ! docker ps --format '{{.Names}}' | grep -q "^${container_name}$"; then
    err "Failed to start registry mirror for $registry"
    docker logs "$container_name" 2>/dev/null | tail -5
    exit 1
  fi
  info "Registry mirror for $registry is running (http://$HOST_IP:$port)."
done

info "All registry mirrors are running."
info "Add to Makefile / deploy to use: make registry-mirror"
