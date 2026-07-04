# ─── Talos + Vagrant + Cilium automation ─────────────────────────────────────

CLUSTER_NAME ?= talos
CONTROL_COUNT ?= 3
WORKER_COUNT ?= 1
CP_CPUS      ?= 2
CP_MEMORY    ?= 2048
WORKER_CPUS  ?= 1
WORKER_MEMORY?= 1024
DISK_SIZE    ?= 10G
SUBNET       ?= 192.168.121
VIP          ?= $(SUBNET).100

export CLUSTER_NAME CONTROL_COUNT WORKER_COUNT
export CP_CPUS CP_MEMORY WORKER_CPUS WORKER_MEMORY DISK_SIZE SUBNET VIP

.PHONY: help bootstrap up deploy status down destroy clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

bootstrap: ## [sudo] Install all prerequisites (Vagrant, talosctl, kubectl, etc.)
	sudo bash scripts/bootstrap.sh

up: ## Start VMs with vagrant-libvirt
	vagrant up --provider=libvirt

status: ## Show VM status
	@echo "=== Vagrant status ==="
	vagrant status
	@echo ""
	@echo "=== VM IPs ==="
	@scripts/fetch-ips.sh

deploy: ## Deploy Talos cluster (generate config, bootstrap, apply workers)
	bash scripts/deploy.sh

deploy-cilium: ## Deploy Talos + install Cilium CNI
	bash scripts/deploy.sh --cilium

kubeconfig: ## Export paths for kubeconfig and talosconfig
	$(eval KUBECONFIG:=$(shell pwd)/kubeconfig)
	$(eval TALOSCONFIG:=$(shell pwd)/talosconfig)
	@echo "export KUBECONFIG=$(KUBECONFIG)"
	@echo "export TALOSCONFIG=$(TALOSCONFIG)"

health: ## Check Talos & K8s cluster health
	@echo "--- Talos health ---"
	-talosctl health
	@echo ""
	@echo "--- Nodes ---"
	-kubectl get nodes -o wide

destroy: ## Destroy all VMs (keeps downloaded ISO)
	vagrant destroy -f

clean: destroy ## Destroy VMs + remove generated configs and ISO
	-rm -f talosconfig controlplane.yaml worker.yaml kubeconfig
	-rm -f /tmp/metal-amd64.iso
	@echo "Cleanup done."
