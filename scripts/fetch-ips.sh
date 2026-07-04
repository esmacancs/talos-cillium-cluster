#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-talos}"

for name in $(virsh list --name 2>/dev/null | grep "vagrant_${CLUSTER_NAME}"); do
  ip=$(virsh domifaddr "$name" 2>/dev/null \
    | grep ipv4 | awk '{print $4}' | cut -d/ -f1)
  echo "  $name  =>  ${ip:-(no IP)}"
done
