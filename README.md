# Talos HA Cluster with Vagrant + Cilium on Ubuntu 24.04

Automated **3-control-plane + 1-worker** Talos Linux Kubernetes cluster using
Vagrant with the libvirt (KVM) provider, with Cilium as the CNI (kube-proxy
replacement + L2 load-balancer announcements).

## Architecture

```
                          ┌──────────────────────┐
                          │   VIP 192.168.121.100 │
                          │  (floating across CPs)│
                          └──────────┬───────────┘
                                     │
              ┌──────────────────────┼──────────────────────┐
              │                      │                      │
     ┌────────▼────────┐  ┌─────────▼────────┐  ┌─────────▼────────┐
     │talos-cp-1       │  │talos-cp-2        │  │talos-cp-3        │
     │ 2 CPU / 2G RAM  │  │ 2 CPU / 2G RAM   │  │ 2 CPU / 2G RAM  │
     │ etcd + apiserver│  │ etcd + apiserver │  │ etcd + apiserver│
     │ 192.168.121.x   │  │ 192.168.121.x    │  │ 192.168.121.x   │
     └─────────────────┘  └──────────────────┘  └──────────────────┘
                                                                   
     ┌──────────────────────────────────────────────────────────────┐
     │  talos-worker-1                                              │
     │  1 CPU / 1G RAM                                              │
     │  192.168.121.x                                               │
     └──────────────────────────────────────────────────────────────┘
```

## Requirements

| Component          | Version     |
|--------------------|-------------|
| Ubuntu             | 24.04 LTS   |
| Vagrant            | 2.4+        |
| vagrant-libvirt    | latest      |
| libvirt / KVM      | system-wide |
| talosctl           | v1.9.5      |
| kubectl            | stable      |
| helm               | 3.x         |
| cilium CLI         | latest      |

## Project Structure

```
vagrant-talos/
├── Vagrantfile               # 4 VMs (3 CP + 1 worker)
├── Makefile                  # All commands via make
├── .env.example              # Environment variables reference
├── config/
│   ├── cluster-patch.yaml    # Disables default CNI + kube-proxy
│   ├── controlplane-patch.yaml
│   └── worker-patch.yaml
├── scripts/
│   ├── bootstrap.sh          # Install all prerequisites (run as root)
│   ├── deploy.sh             # Full cluster deployment (auto)
│   └── fetch-ips.sh          # Show VM IPs
└── manifests/
    ├── 01-cilium-l2.yaml     # Cilium IP pool + L2 announcement policy
    └── 02-playground.yaml    # Test deployment (nginx)
```

---

## Step-by-Step Instructions

### Step 1: Clone the project

```bash
git clone <your-repo-url> vagrant-talos
cd vagrant-talos
```

### Step 2: Install dependencies

```bash
sudo make bootstrap
```

This installs:
- `qemu-kvm`, `libvirt-daemon-system`, `libvirt-clients`
- Vagrant + `vagrant-libvirt` plugin
- `talosctl`, `kubectl`, `helm`, `cilium` CLI

**You must log out and log back in** (or run `newgrp libvirt`) for the
`libvirt` / `kvm` group membership to take effect.

### Step 3: Verify virtualization

```bash
kvm-ok
```

Should say: *"KVM acceleration can be used"*

```bash
sudo systemctl status libvirtd
```

Should show: `active (running)`

### Step 4: Start the VMs

```bash
make up
```

This runs `vagrant up --provider=libvirt` which:
1. Downloads the Talos `metal-amd64.iso` from GitHub (if not already cached)
2. Creates 4 KVM virtual machines:
   - `talos-control-plane-1` (2 CPU / 2G RAM / 10G disk)
   - `talos-control-plane-2` (2 CPU / 2G RAM / 10G disk)
   - `talos-control-plane-3` (2 CPU / 2G RAM / 10G disk)
   - `talos-worker-1` (1 CPU / 1G RAM / 10G disk)
3. Each VM boots from the Talos ISO and enters maintenance mode

**Wait 2–5 minutes** for all VMs to boot. You can watch progress with:

```bash
virsh list
```

### Step 5: Check VM IPs

```bash
make status
```

You should see output like:

```
=== Vagrant status ===
talos-control-plane-1          running (libvirt)
talos-control-plane-2          running (libvirt)
talos-control-plane-3          running (libvirt)
talos-worker-1                 running (libvirt)

=== VM IPs ===
  vagrant_talos-control-plane-1  =>  192.168.121.203
  vagrant_talos-control-plane-2  =>  192.168.121.119
  vagrant_talos-control-plane-3  =>  192.168.121.125
  vagrant_talos-worker-1         =>  192.168.121.69
```

Write these down — they're used internally by the deploy script.

### Step 6: Deploy the HA cluster

```bash
make deploy-cilium
```

This runs `scripts/deploy.sh --cilium` and performs these steps automatically:

| Step | Action                                                                    |
|------|---------------------------------------------------------------------------|
| 1    | Discover all VM IPs via `virsh`                                           |
| 2    | Generate `controlplane.yaml` and `worker.yaml` with `talosctl gen config` |
| 3    | Wait for each node to reach maintenance mode                              |
| 4    | Apply config to **all 3 control planes** (with VIP + unique hostname)     |
| 5    | Wait 60s for etcd to initialize                                           |
| 6    | **Bootstrap** etcd on the first control plane (`talosctl bootstrap`)      |
| 7    | Wait for cluster health (`talosctl health --wait-timeout=10m`)             |
| 8    | Retrieve `kubeconfig`                                                     |
| 9    | Apply config to the worker node                                           |
| 10   | Wait until all 4 nodes are `Ready`                                        |
| 11   | Install Gateway API CRDs                                                  |
| 12   | Install **Cilium** via Cilium CLI (`cilium install`, wraps Helm)          |
| 13   | Apply Cilium IP pool + L2 announcement policy                             |

**Note:** The first time a control plane is configured without a CNI,
it takes 5–10 minutes to settle. The script waits for this. Be patient.

### Cilium Installation: Two-Stage Approach

Cilium is installed in two stages for GitOps management:

1. **Stage 1 — Bootstrap (`scripts/deploy.sh`)**:
   - `cilium install` is called via the Cilium CLI, which internally invokes Helm
   - Runs with kube-proxy replacement and L2 announcement features
   - Installs Cilium 1.19.x into `kube-system` as a Helm release named `cilium`
   - This provides immediate CNI functionality so the cluster can schedule workloads

2. **Stage 2 — GitOps Adoption (`make setup-flux`)**:
   - `make setup-flux` bootstraps FluxCD into the cluster
   - A Flux `HelmRelease` manifest in `clusters/default/cilium-helm-release.yaml` references the same chart
   - Flux adopts the existing Helm release (same name, same namespace) and takes over management
   - On first reconcile, Flux upgrades Cilium to the version specified in the HelmRelease (e.g. 1.19.3 → 1.19.5)
   - All subsequent Cilium version changes are managed by updating the HelmRelease YAML and pushing to git

**Why not install directly via Flux?** The cluster has no CNI initially — pods (including Flux controllers) can't schedule until Cilium is running. The manual `cilium install` breaks this circular dependency.

### Step 7: Verify the cluster

```bash
make health
```

Expected output:

```
--- Talos health ---
[INFO] All health checks passed

--- Nodes ---
NAME                    STATUS   ROLES                  AGE   VERSION
talos-control-plane-1   Ready    control-plane         5m    v1.34.1
talos-control-plane-2   Ready    control-plane         4m    v1.34.1
talos-control-plane-3   Ready    control-plane         4m    v1.34.1
talos-worker-1          Ready    <none>                3m    v1.34.1
```

Also verify Cilium:

```bash
cilium status
```

All components should show `OK`.

### Step 8: Deploy a test application

```bash
kubectl apply -f manifests/02-playground.yaml
```

Check the LoadBalancer got an IP:

```bash
kubectl get svc -n playground
```

Expected:

```
NAME                       TYPE           CLUSTER-IP     EXTERNAL-IP       PORT(S)
playground-nginx-service   LoadBalancer   10.111.180.4   192.168.121.160   80:30597/TCP
```

Test it:

```bash
curl http://192.168.121.160
```

You should see the nginx welcome page.

---

## HA Behavior

The cluster uses a **virtual IP (VIP)** at `192.168.121.100`:

- The VIP floats across all 3 control plane nodes
- If one control plane fails, another takes over the VIP
- `kubeconfig` points to `https://192.168.121.100:6443` — single endpoint that's always available
- etcd runs on all 3 control planes with Raft consensus

**Test HA by rebooting a control plane:**

```bash
talosctl -n 192.168.121.119 reboot
```

The cluster remains operational. The VIP shifts to another CP automatically.

---

## Customization

Copy the example env file and edit:

```bash
cp .env.example .env
```

All supported variables:

| Variable                  | Default             | Description                              |
|---------------------------|---------------------|------------------------------------------|
| `CLUSTER_NAME`            | `talos`             | Cluster name (also VM name prefix)       |
| `CONTROL_COUNT`           | `3`                 | Number of control plane nodes            |
| `WORKER_COUNT`            | `1`                 | Number of worker nodes                   |
| `CP_CPUS`                 | `2`                 | vCPUs per control plane                  |
| `CP_MEMORY`               | `2048`              | RAM (MB) per control plane               |
| `WORKER_CPUS`             | `1`                 | vCPUs per worker                         |
| `WORKER_MEMORY`           | `1024`              | RAM (MB) per worker                      |
| `DISK_SIZE`               | `10G`               | Disk per VM                              |
| `SUBNET`                  | `192.168.121`       | libvirt default subnet                   |
| `VIP`                     | `192.168.121.100`   | Virtual IP for apiserver HA              |
| `INSTALL_DISK`            | `/dev/vda`          | Talos install target                     |
| `ALLOW_SCHED_ON_CP`       | `false`             | Allow pods on control plane nodes        |
| `CILIUM_IP_POOL_START`    | `192.168.121.160`   | First IP in Cilium LB pool               |
| `CILIUM_IP_POOL_STOP`     | `192.168.121.170`   | Last IP in Cilium LB pool                |

### Single-node cluster (testing only)

```bash
export CONTROL_COUNT=1
export WORKER_COUNT=0
export ALLOW_SCHED_ON_CP=true
make up && make deploy-cilium
```

---

## Make Targets

| `make` target    | Description                                          |
|------------------|------------------------------------------------------|
| `bootstrap`      | Install all prerequisites (run as root)              |
| `up`             | `vagrant up --provider=libvirt`                      |
| `status`         | Show VM status + IPs                                 |
| `deploy`         | Deploy Talos cluster (no CNI)                        |
| `deploy-cilium`  | Deploy Talos + install Cilium (via Cilium CLI/Helm)  |
| `setup-flux`     | Bootstrap FluxCD + adopt Cilium/longhorn via GitOps   |
| `full-deploy`    | `up` + `deploy-cilium` + `setup-flux` (end-to-end)   |
| `health`         | Show Talos health + kubectl get nodes                |
| `kubeconfig`     | Print export commands for KUBECONFIG/TALOSCONFIG     |
| `destroy`        | Destroy all VMs (keeps ISO)                          |
| `clean`          | Destroy VMs + remove configs and ISO                 |

---

## Troubleshooting

### VMs don't get IPs

Run manually:
```bash
virsh net-dhcp-leases default
```

### Node stuck in maintenance mode after apply

Check logs:
```bash
sudo tail -f /tmp/talos-control-plane-1.log
```

### Cilium not starting

Restart Cilium pods:
```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart ds/cilium-envoy
kubectl -n kube-system rollout restart deployment/cilium-operator
```

### `curl: Failed to connect` to LoadBalancer IP

Ensure pods are scheduled:
```bash
kubectl get pods -n playground
```
If pods are `Pending`, you may need `ALLOW_SCHED_ON_CP=true` (no worker node).

### Reset the cluster completely

```bash
make clean
# Then start fresh:
make up && make deploy-cilium
```

---

## References

- [Talos docs – Vagrant & Libvirt](https://docs.siderolabs.com/talos/v1.9/platform-specific-installations/virtualized-platforms/vagrant-libvirt)
- [Creating a Talos cluster with Cilium CNI on Proxmox](https://unixorn.github.io/post/homelab/k8s/01-talos-with-cilium-cni-on-proxmox/)
- [Talos Linux](https://www.siderolabs.com/talos-linux/)
- [Cilium](https://cilium.io/)



run caddy on host machine to access from local machine

Add to local machine `/etc/hosts`:
```
10.0.170.11  sarma.local grafana.local hubble.local kite.local playground.local k8s.local
```

Then access `https://sarma.local`, `https://grafana.local`, etc.

HTTPRoutes are managed via GitOps (Flux). Check `clusters/default/` for definitions.