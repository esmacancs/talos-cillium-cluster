#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-talos}"

# Match both vagrant_<name> and <folder>_<name> patterns
for name in $(virsh list --name 2>/dev/null | grep -i "${CLUSTER_NAME}-control-plane\|${CLUSTER_NAME}-worker"); do
  ip=$(virsh domifaddr "$name" 2>/dev/null \
    | grep ipv4 | awk '{print $4}' | cut -d/ -f1)
  echo "  $name  =>  ${ip:-(no IP)}"
done
