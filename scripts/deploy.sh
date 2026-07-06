#!/usr/bin/env bash
set -euo pipefail

# ─── Full Talos cluster deploy script ────────────────────────────────────────
# Prerequisite:  scripts/bootstrap.sh has been run (as root).
#                Vagrant VMs are up  (vagrant up --provider=libvirt).
#
# Usage:  ./scripts/deploy.sh [--cilium]

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${CYAN}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR ]${NC} $*" >&2; }

# ─── Load env overrides ──────────────────────────────────────────────────────
CLUSTER_NAME="${CLUSTER_NAME:-talos}"
CONTROL_COUNT="${CONTROL_COUNT:-3}"
WORKER_COUNT="${WORKER_COUNT:-1}"
ALLOW_SCHED_ON_CP="${ALLOW_SCHED_ON_CP:-false}"
SUBNET="${SUBNET:-192.168.121}"
VIP="${VIP:-${SUBNET}.100}"
INSTALL_DISK="${INSTALL_DISK:-/dev/vda}"
TALOS_VERSION="${TALOS_VERSION:-v1.13}"
ISO_PATH="${ISO_PATH:-/tmp/metal-amd64.iso}"
export TALOSCONFIG="${TALOSCONFIG:-$(pwd)/talosconfig}"

# Ensure ISO is downloaded
if [ ! -f "$ISO_PATH" ]; then
  info "Downloading Talos ISO to $ISO_PATH ..."
  wget --progress=bar:force "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso" -O "$ISO_PATH" || \
    curl -fL -o "$ISO_PATH" "https://github.com/siderolabs/talos/releases/latest/download/metal-amd64.iso" || {
      err "Failed to download Talos ISO"
      exit 1
    }
fi

# ─── 1. Get VM IPs from virsh ──────────────────────────────────────────────
info "Discovering VM IPs ..."
get_vm_ips() {
  local pattern="$1"
  virsh list --name 2>/dev/null | grep -i "$pattern" | while read -r name; do
    virsh domifaddr "$name" 2>/dev/null \
      | grep ipv4 | awk '{print $4}' | cut -d/ -f1
  done | sort -u
}

CP_IPS=()
mapfile -t CP_IPS < <(get_vm_ips "${CLUSTER_NAME}-control-plane")
WORKER_IPS=()
mapfile -t WORKER_IPS < <(get_vm_ips "${CLUSTER_NAME}-worker")

if [[ ${#CP_IPS[@]} -eq 0 ]]; then
  err "No control-plane VMs found. Run: vagrant up --provider=libvirt"
  exit 1
fi

info "Control-plane IPs: ${CP_IPS[*]}"
info "Worker IPs:        ${WORKER_IPS[*]:-(none)}"
FIRST_CP="${CP_IPS[0]}"

# ─── NTP server ──────────────────────────────────────────────────────────
# Use the libvirt gateway (host) which now runs chrony
NTP_SERVER="${NTP_SERVER:-192.168.121.1}"
info "NTP server: $NTP_SERVER"

# ─── Helper: wait for Talos maintenance mode on a node ─────────────────────
wait_for_maintenance() {
  local ip=$1
  local max=20
  info "Waiting for node $ip to reach maintenance mode ..."
  for i in $(seq 1 $max); do
    # Quick check: if node is already configured, skip maintenance wait
    if output=$(talosctl -n "$ip" version 2>&1); then
      if echo "$output" | grep -q "Server:"; then
        info "Node $ip is already configured — skipping."
        return 1
      fi
    fi
    # Check for maintenance mode
    if output=$(talosctl -n "$ip" version --insecure 2>&1); then
      if echo "$output" | grep -q "Server:"; then
        info "Node $ip ready in maintenance mode."
        return 0
      fi
    fi
    if [ "$i" -eq 1 ] && [ -z "${output:-}" ]; then
      warn "Node $ip returned empty — retrying ..."
    fi
    sleep 10
  done
  err "Node $ip not reachable in maintenance or configured state."
  exit 1
}

# ─── 3. Generate cluster config (with expanded vars) ─────────────────────────
info "Generating Talos configuration ..."
rm -f talosconfig controlplane.yaml worker.yaml

# Build a full patch with all cluster settings expanded
LOCAL_MIRROR="${LOCAL_MIRROR:-192.168.121.1}"
LONGHORN_ENABLED="${LONGHORN_ENABLED:-${LONGHORN:-false}}"
LONGHORN_DISK_SIZE="${LONGHORN_DISK_SIZE:-}"

DISKS_CONFIG=""
if [ -n "$LONGHORN_DISK_SIZE" ]; then
  DISKS_CONFIG=$'  disks:\n    - device: /dev/vdb\n      partitions:\n        - mountpoint: /var/mnt/longhorn\n          size: 0'
fi
cat > /tmp/cluster-full-patch.yaml <<EOF
machine:
  time:
    disabled: false
    bootTimeout: 15m
    servers:
      - ${NTP_SERVER}
  registries:
    mirrors:
      ghcr.io:
        endpoints:
          - http://${LOCAL_MIRROR}:5001
          - https://ghcr.io
      registry.k8s.io:
        endpoints:
          - http://${LOCAL_MIRROR}:5002
          - https://registry.k8s.io
      quay.io:
        endpoints:
          - http://${LOCAL_MIRROR}:5003
          - https://quay.io
      factory.talos.dev:
        endpoints:
          - https://factory.talos.dev
  install:
    image: factory.talos.dev/installer/c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac:v1.13.4
  kernel:
    modules:
      - name: iscsi_tcp
      - name: nbd
      - name: configfs
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options:
          - bind
          - rshared
          - rw
${DISKS_CONFIG}
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  allowSchedulingOnControlPlanes: ${ALLOW_SCHED_ON_CP}
  apiServer:
    certSANs:
      - ${VIP}
EOF

# Remove mirror block from patch if registries are unreachable (cleans up output)
MIRROR_PORTS=(5001 5002 5003)
all_reachable=true
for port in "${MIRROR_PORTS[@]}"; do
  if ! timeout 2 bash -c "echo >/dev/tcp/${LOCAL_MIRROR}/${port}" 2>/dev/null; then
    all_reachable=false
    break
  fi
done
if ! $all_reachable; then
  info "Local registry mirrors not reachable at ${LOCAL_MIRROR}:{5001-5003} — skipping mirror config."
  # Re-generate patch without mirrors
  cat > /tmp/cluster-full-patch.yaml <<EOF
machine:
  time:
    disabled: false
    bootTimeout: 15m
    servers:
      - ${NTP_SERVER}
  install:
    image: factory.talos.dev/installer/c9078f9419961640c712a8bf2bb9174933dfcf1da383fd8ea2b7dc21493f8bac:v1.13.4
  kernel:
    modules:
      - name: iscsi_tcp
      - name: nbd
      - name: configfs
  kubelet:
    extraMounts:
      - destination: /var/mnt/longhorn
        type: bind
        source: /var/mnt/longhorn
        options:
          - bind
          - rshared
          - rw
${DISKS_CONFIG}
cluster:
  network:
    cni:
      name: none
  proxy:
    disabled: true
  allowSchedulingOnControlPlanes: ${ALLOW_SCHED_ON_CP}
  apiServer:
    certSANs:
      - ${VIP}
EOF
else
  info "Local registry mirrors reachable at ${LOCAL_MIRROR}:{5001-5003} — will cache image pulls."
fi

talosctl gen config "$CLUSTER_NAME" "https://${VIP}:6443" \
  --install-disk "$INSTALL_DISK" \
  --config-patch @/tmp/cluster-full-patch.yaml

# Remove auto-generated hostname from controlplane.yaml (we set it per-node)
sed -i '/^  hostname:/d' controlplane.yaml 2>/dev/null || true
sed -i '/^    hostname:/d' worker.yaml 2>/dev/null || true

# Set talosconfig endpoints
talosctl config endpoint "${CP_IPS[@]}"

# ─── 3. Apply configs to control-plane nodes ───────────────────────────────
for i in "${!CP_IPS[@]}"; do
  ip="${CP_IPS[$i]}"
  idx=$((i + 1))

  if ! wait_for_maintenance "$ip"; then
    info "Skipping already-configured node $ip."
    continue
  fi

  # Build per-node patch (only VIP interface)
  cat > "/tmp/${CLUSTER_NAME}-cp-${idx}-patch.yaml" <<EOF
machine:
  network:
    interfaces:
      - deviceSelector:
          physical: true
        dhcp: true
        vip:
          ip: ${VIP}
EOF

  # Reboot to clear any partial config from a previous run
  virsh_name=$(virsh list --name 2>/dev/null | grep -i "${CLUSTER_NAME}-control-plane-${idx}")
  if [ -n "$virsh_name" ]; then
    info "Rebooting $virsh_name to clear partial state ..."
    virsh reboot "$virsh_name" 2>/dev/null || true
    sleep 30
    if ! wait_for_maintenance "$ip"; then
      info "Skipping node $ip."
      continue
    fi
  fi

  info "Applying config to control-plane node $idx ($ip) ..."
  for attempt in 1 2 3; do
    output=$(talosctl -n "$ip" apply-config --insecure \
      --file controlplane.yaml \
      --config-patch @"/tmp/${CLUSTER_NAME}-cp-${idx}-patch.yaml" 2>&1 || true)
    echo "$output" | grep -v "^$" || true
    if echo "$output" | grep -qi "applied"; then
      info "Config applied to CP node $idx."
      break
    fi
    if [ "$attempt" -lt 3 ]; then
      warn "Attempt $attempt failed for $ip, retrying in 15s ..."
      sleep 15
    else
      err "Failed to apply config to $ip after 3 attempts."
      exit 1
    fi
  done
done

# ─── 4. Wait for first CP to finish installing + reboot, then bootstrap ────
info "Waiting for $FIRST_CP to finish install and boot from disk ..."
for i in $(seq 1 120); do
  if talosctl -n "$FIRST_CP" version 2>&1 | grep -q "Server:"; then
    info "$FIRST_CP is fully booted (attempt $i)."
    break
  fi
  if [ "$i" -eq 120 ]; then
    warn "Node not fully booted after 20 minutes — continuing ..."
  fi
  sleep 10
done

info "Waiting for NTP sync on $FIRST_CP ..."
for i in $(seq 1 60); do
  if talosctl -n "$FIRST_CP" time &>/dev/null; then
    info "NTP sync OK on $FIRST_CP."
    break
  fi
  if [ "$i" -eq 60 ]; then
    warn "NTP sync timeout — continuing anyway ..."
  fi
  sleep 10
done

info "Bootstrapping etcd on $FIRST_CP ..."
for attempt in $(seq 1 10); do
  if talosctl -n "$FIRST_CP" bootstrap 2>/dev/null; then
    info "Bootstrap initiated on $FIRST_CP."
    break
  fi
  if [ "$attempt" -lt 10 ]; then
    warn "Bootstrap attempt $attempt failed, retrying in 30s ..."
    sleep 30
  else
    warn "Bootstrap failed after 10 attempts; retrying one final time ..."
    talosctl -n "$FIRST_CP" bootstrap
  fi
done

# Wait for bootstrap to complete
info "Waiting for cluster to become healthy ..."
talosctl -n "$FIRST_CP" health --wait-timeout=10m || warn "Health check took long; continuing ..."

# ─── 5. Retrieve kubeconfig ────────────────────────────────────────────────
info "Retrieving kubeconfig ..."
talosctl -n "$FIRST_CP" kubeconfig ./kubeconfig
export KUBECONFIG="${KUBECONFIG:-$(pwd)/kubeconfig}"

# ─── 6. Apply configs to worker nodes ──────────────────────────────────────
for i in "${!WORKER_IPS[@]}"; do
  ip="${WORKER_IPS[$i]}"
  idx=$((i + 1))

  wait_for_maintenance "$ip"

  # Use auto-generated hostname (no patch needed) to avoid conflict with HostnameConfig

  info "Applying config to worker node $idx ($ip) ..."
  talosctl -n "$ip" apply-config --insecure \
    --file worker.yaml
done

# ─── 7. Wait for all nodes to be Ready ─────────────────────────────────────
info "Waiting for all nodes to be Ready ..."
for i in $(seq 1 30); do
  ready=$(kubectl get nodes --no-headers 2>/dev/null \
    | awk '{print $2}' | grep -c "^Ready" || true)
  total=$((CONTROL_COUNT + WORKER_COUNT))
  if [[ "$ready" -ge "$total" ]]; then
    info "All $total nodes are Ready!"
    break
  fi
  sleep 10
done

kubectl get nodes -o wide

# ─── 8. (Optional) Install Cilium ──────────────────────────────────────────
if [[ "${1:-}" == "--cilium" ]]; then
  info "Installing Cilium CNI ..."

  # Gateway API CRDs
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml

  helm repo add cilium https://helm.cilium.io/ 2>/dev/null || helm repo update cilium
  helm repo update 2>/dev/null || true

  CILIUM_HELM_SET=(
    --helm-set=ipam.mode=kubernetes
    --helm-set=kubeProxyReplacement=true
    --helm-set=securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
    --helm-set=securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
    --helm-set=cgroup.autoMount.enabled=false
    --helm-set=cgroup.hostRoot=/sys/fs/cgroup
    --helm-set=l2announcements.enabled=true
    --helm-set=externalIPs.enabled=true
    --set gatewayAPI.enabled=true
    --helm-set=devices=e+
    --helm-set=operator.replicas=1
  )
  if cilium status --wait --wait-duration=10s 2>/dev/null; then
    cilium upgrade "${CILIUM_HELM_SET[@]}"
  else
    cilium install "${CILIUM_HELM_SET[@]}"
  fi
  cilium status --wait

  # Apply L2 announcement policy + IP pool (substitute shell variables first)
  export CILIUM_IP_POOL_START="${CILIUM_IP_POOL_START:-192.168.121.160}"
  export CILIUM_IP_POOL_STOP="${CILIUM_IP_POOL_STOP:-192.168.121.170}"
  for f in manifests/*.yaml; do
    sed 's/\${\([A-Z_]*\):-[^}]*}/\${\1}/g' "$f" | envsubst | kubectl apply -f -
  done

  info "Cilium installed. Verify with: cilium status"
fi

# ─── 9. Summary ────────────────────────────────────────────────────────────
info "── Cluster ready ────────────────────────────────────────────────────"
info "Cluster name : $CLUSTER_NAME"
info "API VIP      : https://${VIP}:6443"
info "Nodes        :"
kubectl get nodes -o wide | awk '{print "  "$0}'
info ""
info "kubeconfig   : $(pwd)/kubeconfig"
info "talosconfig  : $TALOSCONFIG"
info ""
info "Quick cmds:"
info "  export KUBECONFIG=$(pwd)/kubeconfig"
info "  kubectl get nodes"
info "  talosctl -n ${FIRST_CP} health"
