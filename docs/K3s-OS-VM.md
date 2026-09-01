# HCloud — OpenStack IaaS on the Dell MX7000, with K3s on top

**Status:** design + implementation runbook. **Target:** the purchased $150,000 platform
(Dell PowerEdge MX7000 chassis, MX750c sleds, GPU node, ~50 TB storage) now racked in the
HSPH IT server room.

**Decision recorded here:** build **OpenStack** on the bare metal first, so that
collaborators get self-service VMs, projects, and quotas under one management plane
(the NERC experience, owned by us) — and then build the **K3s** cluster that runs the
migrated NERC stack **on OpenStack VMs**, not on the bare metal.

> **Trade-off, stated once and then set aside.** The virtualization layer costs ~18–22%
> of aggregate RAM and adds an OpenStack operations burden (see
> [§2 Capacity budget](#2-capacity-budget--what-the-layer-costs) and
> [§17 Risk register](#17-risk-register--rollback)). It buys multi-tenant self-service,
> hard tenant isolation, per-project quotas, snapshots, and non-container workloads
> (Windows, legacy appliances, per-student sandboxes) that a bare K3s cluster cannot
> offer. The mitigations that make this work are: **databases keep local NVMe** (§6),
> **huge pages + CPU pinning** for the DB guests (§10), and **the bare-metal K3s path
> stays intact as rollback** (§17).

---

## Table of contents

1. [Target architecture](#1-target-architecture)
2. [Capacity budget — what the layer costs](#2-capacity-budget--what-the-layer-costs)
3. [Software versions and choices](#3-software-versions-and-choices)
4. [Phase 0 — physical, firmware, BIOS](#4-phase-0--physical-firmware-bios)
5. [Network plan](#5-network-plan)
6. [Storage plan](#6-storage-plan)
7. [Phase 1 — deploy host and base OS](#7-phase-1--deploy-host-and-base-os)
8. [Phase 2 — Ceph via cephadm](#8-phase-2--ceph-via-cephadm)
9. [Phase 3 — OpenStack via Kolla-Ansible](#9-phase-3--openstack-via-kolla-ansible)
10. [Phase 4 — flavors, images, aggregates, performance](#10-phase-4--flavors-images-aggregates-performance)
11. [Phase 5 — GPU passthrough](#11-phase-5--gpu-passthrough)
12. [Phase 6 — collaborator self-service](#12-phase-6--collaborator-self-service)
13. [Phase 7 — the K3s cluster on OpenStack VMs](#13-phase-7--the-k3s-cluster-on-openstack-vms)
14. [Phase 8 — Kubernetes/OpenStack integration](#14-phase-8--kubernetesopenstack-integration)
15. [Phase 9 — migrate the NERC stack](#15-phase-9--migrate-the-nerc-stack)
16. [Day-2 operations](#16-day-2-operations)
17. [Risk register + rollback](#17-risk-register--rollback)
18. [Effort and sequencing](#18-effort-and-sequencing)
19. [Validation checklist](#19-validation-checklist)
20. [Appendix A — cheaper ways to get the same self-service](#appendix-a--cheaper-ways-to-get-the-same-self-service)
21. [Appendix B — reference inventory files](#appendix-b--reference-inventory-files)

---

## 1. Target architecture

```
                        Internet
                            │
                  Cloudflare Tunnel (no static public IP needed)
                            │
┌───────────────────────────┴─────────────────────────────────────────────────┐
│  OpenStack (Kolla-Ansible, containerized control plane)                     │
│                                                                             │
│  Keystone · Horizon/Skyline · Glance · Placement · Nova · Neutron(OVN)      │
│  Cinder · Barbican · (Octavia optional) · Prometheus/Grafana                │
│                                                                             │
│  ┌── project: hcloud-platform ──────────┐  ┌── project: lab-<collab> ────┐  │
│  │  k3s-server-1  k3s-server-2  ...     │  │  vm-01  vm-02  (self-serve) │  │
│  │  k3s-db-ch     k3s-db-rocks          │  │  quota: 16 vCPU/64 GB/2 TB  │  │
│  │  k3s-agent-*   k3s-gpu-1             │  └─────────────────────────────┘  │
│  │     ↑ K3s cluster: the migrated      │  ┌── project: teaching ────────┐  │
│  │       NERC stack + public site       │  │  student sandboxes          │  │
│  └──────────────────────────────────────┘  └─────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
        │                │                │                    │
   sled1 (ctl+cmp)  sled2 (ctl+cmp)  sled3 (ctl+cmp)      gpu1 (cmp, 4× L40S)
        │                │                │                    │
   local NVMe       local NVMe       local NVMe            local NVMe
   (cinder-lvm)     (cinder-lvm)     (cinder-lvm)          (cinder-lvm)
        └────────────────┴────────────────┴────────────────────┘
                   Ceph (cephadm) on the SAS/bulk tier
              RBD → Glance images, Nova root disks, general volumes
              RGW → S3 endpoint (backup target; MinIO stays in K3s)
```

**Two-tier storage is the crux of the design.** General VM disks live on Ceph so that
live migration, snapshots, and self-service work normally. The three data-heavy stores
(ClickHouse ~2.4 TB, RocksDB ~1.6 TiB, MinIO ~2.9 TiB) get **host-local NVMe** attached
to pinned VMs, because putting them behind Ceph RBD reintroduces exactly the replicated-
network-storage indirection this migration is leaving behind at NERC.

### Node roles (reference configuration — adjust to as-delivered)

| Host | Hardware | OpenStack role | Reserved for control plane | Available to guests |
|---|---|---|---|---|
| `deploy` | 1U R660, or the `pc` box initially | Kolla-Ansible deploy host, MAAS/PXE, backups, monitoring | all | — |
| `sled1` | MX750c, 64c/128t, 768 GB | controller + compute + Ceph mon/mgr | ~96 GB, 12 threads | ~656 GB |
| `sled2` | MX750c, 64c/128t, 768 GB | controller + compute + Ceph mon/mgr | ~96 GB, 12 threads | ~656 GB |
| `sled3` | MX750c, 64c/128t, 768 GB | controller + compute + Ceph mon | ~96 GB, 12 threads | ~656 GB |
| `gpu1` | R760xa, 32c, 512 GB, 4× L40S | compute only (PCI passthrough) | ~24 GB, 4 threads | ~488 GB |

> **Strongly recommended:** a small dedicated management node (1U R660, or the existing
> `pc`) as the **deploy host**. It holds the Kolla-Ansible venv, `/etc/kolla`, inventory,
> and passwords; it must not be a node it deploys. Never run `kolla-ansible` from a
> controller — a failed `bootstrap-servers` on your own deploy host is unpleasant.
>
> If budget allows, move the OpenStack control plane onto **three 1U R660s** and keep the
> MX750c sleds as pure compute. That returns ~288 GB of blade RAM to guests and makes
> control-plane maintenance independent of workload nodes. The converged layout above is
> the fallback when only the chassis was purchased.

---

## 2. Capacity budget — what the layer costs

Reference config: 3× 768 GB sleds + 1× 512 GB GPU node = **2,816 GB** physical RAM,
**224 cores / 448 threads**, ~50 TB storage.

| Consumer | RAM | Notes |
|---|---|---|
| Host OS, kernel, systemd, agents (×4) | ~64 GB | 16 GB per host |
| Kolla control plane (×3 controllers) | ~210 GB | MariaDB/Galera, RabbitMQ, Keystone, Nova, Neutron+OVN, Glance, Cinder, Placement, Horizon, Barbican, memcached, HAProxy/keepalived, Prometheus |
| Ceph MON/MGR (×3) | ~24 GB | 8 GB each |
| Ceph OSDs, if colocated on sleds | ~80 GB | budget 5 GB per OSD; zero if OSDs live on a separate storage node |
| Reserved-host headroom (`reserved_host_memory_mb`) | ~64 GB | prevents OOM-killing qemu |
| **Overhead subtotal** | **~440 GB (≈16%)** | |
| Per-VM hypervisor overhead | ~2–4% of guest RAM | qemu, page tables; more with many small VMs |
| **Net available to guests** | **≈2.30–2.35 TB** | |
| minus guest kernels + kubelet across ~8 VMs | ~24 GB | |
| **Net available to K3s pods** | **≈2.28 TB** | vs ~2.65 TB on bare metal |

**Storage:** 50 TB does not stay 50 TB. Ceph 3× replication turns a 15 TB SAS pool into
5 TB usable; erasure coding 4+2 turns it into 10 TB. This is the second reason the
databases stay on local NVMe — see §6 for the split that keeps ~30 TB usable.

**CPU:** with `hw:cpu_policy=dedicated` a vCPU is a real thread. After reserving 12
threads per controller sled you have ~400 pinnable threads. That is not a constraint here.

---

## 3. Software versions and choices

| Layer | Choice | Why this one |
|---|---|---|
| Host OS | **Ubuntu 24.04 LTS** (`noble`) | matches the `pc` PoC box; supported by Kolla-Ansible and cephadm |
| OpenStack release | the current **SLURP** release (2025.1 "Epoxy", or the newer SLURP if released — confirm on `releases.openstack.org`) | SLURP releases support skip-level upgrades: one upgrade per year instead of two |
| Deployment tool | **Kolla-Ansible** | containerized services, the most widely documented self-managed path, straightforward `deploy`/`upgrade`/`reconfigure` verbs |
| Networking | **Neutron with OVN** | current default; no separate L3 agents, distributed routing, less to operate than ML2/OVS |
| Block storage | **Ceph RBD** (general) + **Cinder LVM on local NVMe** (databases) | see §6 |
| Object storage | **Ceph RGW** for backups; **MinIO stays inside K3s** | the migrated app expects MinIO's endpoint and data; don't re-platform it during a migration |
| Ceph deployment | **cephadm**, deployed separately, consumed by Kolla as *external Ceph* | Kolla-Ansible no longer deploys Ceph itself |
| Dashboard | **Horizon** (enable **Skyline** alongside if collaborators prefer it) | Horizon is the one every OpenStack doc assumes |
| Load balancing for K8s | **MetalLB inside K3s** (Octavia optional, later) | Octavia adds amphora images, a lb-mgmt network, and its own certificate authority; not worth it on day one |
| Kubernetes | **K3s** with embedded etcd, 3 servers | unchanged from the bare-metal plan; same `Route`→`Ingress` conversion path |
| IaC | **OpenTofu/Terraform** for VMs, cloud-init for bootstrap | the K3s cluster must be rebuildable without clicking |

### Alternatives you may prefer

- **Canonical MAAS + Juju/Sunbeam** — snap-based, tightly integrated with Ubuntu, less
  YAML than Kolla, but a smaller community answer-set when something breaks.
- **OpenStack-Ansible** — LXC-based, very flexible, more moving parts.
- **Red Hat OpenStack Services on OpenShift** — supported, but licensed, and it inverts
  the stack (OpenShift underneath OpenStack), which contradicts the K3s decision.

---

## 4. Phase 0 — physical, firmware, BIOS

Do this before any OS install; several settings require a reboot you don't want later.

1. **OME-Modular / iDRAC** on the management VLAN. Set static IPs, strong credentials
   (store in `docs/Secretes/`, git-ignored), NTP, and enable email/SNMP alerting.
2. **Firmware baseline.** Create an OpenManage Enterprise-Modular firmware baseline and
   bring chassis, sleds, MX9116n, PERC, BOSS, and NVMe firmware to the same catalog
   version. Mixed firmware across sleds causes live-migration failures that are miserable
   to diagnose.
3. **BIOS per sled:**
   - System Profile: **Performance** (not `PerfPerWattOS`) — matters for DB latency
   - **Virtualization Technology: Enabled**
   - **SR-IOV Global Enable: Enabled**
   - **VT for Direct I/O (VT-d): Enabled** — required for GPU/NVMe passthrough
   - **Sub-NUMA Clustering: Disabled** (keep NUMA topology simple for pinning)
   - **Node Interleaving: Disabled** (you want NUMA visible, not hidden)
   - Logical Processor (HT): **Enabled**
   - C-States: Disabled or shallow; Turbo: Enabled
4. **BOSS-N1:** RAID1 across the two M.2 — this is the OS mirror.
5. **PERC / NVMe:** see §6 before creating virtual disks. Decide RAID10 vs pass-through
   (HBA/eHBA mode for Ceph OSDs) **now**; changing it later destroys data.
6. **Record the inventory:** service tags, MAC addresses, iDRAC IPs, drive serials into
   `docs/` — you will need MACs for PXE and drive serials for OSD replacement.

---

## 5. Network plan

The MX9116n fabric provides east-west switching between sleds and dual 25/100 GbE
uplinks. Ask HSPH IT for the VLANs below, tagged on the uplinks.

| Purpose | VLAN (example) | Subnet (example) | MTU | Notes |
|---|---|---|---|---|
| Out-of-band management | 10 | 10.10.10.0/24 | 1500 | iDRAC, OME-M. **Never** routable from tenants |
| Host / API internal | 20 | 10.10.20.0/24 | 9000 | `network_interface`, `api_interface`, MariaDB/RabbitMQ traffic |
| Overlay / tunnel | 30 | 10.10.30.0/24 | 9000 | Geneve between compute nodes |
| Storage (Ceph public+cluster) | 40, 41 | 10.10.40.0/24, 10.10.41.0/24 | 9000 | separate cluster net if you can afford the ports |
| External / provider | 50 | campus routable range | 1500/9000 | floating IPs, `neutron_external_interface` |
| Tenant VLAN range (optional) | 600–699 | — | 9000 | only if you want VLAN-backed tenant nets in addition to Geneve |

### MTU: get this right on day one

Three encapsulations stack up in this design: Geneve (Neutron) → the VM's interface →
flannel VXLAN (K3s). Each eats header space, and an MTU mistake here produces the classic
symptom "small requests work, large responses hang".

- Underlay (host, storage, tunnel VLANs): **9000**
- `neutron_global_physnet_mtu: 9000` in `globals.yml`
- Neutron computes Geneve tenant-network MTU automatically (≈8942). VM interfaces pick
  this up **via DHCP** — so do not hard-code 9000 inside the guest.
- K3s flannel: **VM MTU − 50** for VXLAN. If the VM shows 8942, flannel must be ≤8892.
  K3s usually derives this from the interface; verify, don't assume (§19).
- If HSPH IT cannot give you jumbo frames on the uplink, use **1500 everywhere**: Geneve
  tenant MTU ≈1442, flannel ≈1392. Consistency beats size.

Verify end to end before deploying anything on top:

```bash
# host → host on the tunnel VLAN, no fragmentation allowed
ping -M do -s 8972 10.10.30.12
# from inside a VM, to another VM on the same tenant network
ping -M do -s 8914 <peer-vm-ip>
# from inside a pod, to a pod on another node
kubectl run mtu-test --rm -it --image=busybox -- ping -M do -s 8864 <peer-pod-ip>
```

### Floating IPs without a static public IP

The README notes HCloud has no static public IP and serves the world through Cloudflare
Tunnel. That does not change:

- Neutron floating IPs come from a **campus (possibly RFC1918) range** and provide
  **LAN** reachability for collaborators — the point is that a collaborator can attach a
  reachable address to their own VM without asking you.
- **Public** exposure stays Cloudflare Tunnel, running as a pod inside K3s (as today) and
  optionally as a per-project `cloudflared` VM for a collaborator who needs their own
  hostname.
- Ask IT for at least a /26 of floating IPs if collaborators will each want one.

### Security groups

Default project security groups should permit SSH from campus only. For the platform
project, the K3s cluster needs:

| Port | Proto | Scope | Purpose |
|---|---|---|---|
| 6443 | TCP | servers + agents + admin | K3s API |
| 2379–2380 | TCP | servers only | embedded etcd |
| 8472 | UDP | all nodes | flannel VXLAN |
| 10250 | TCP | all nodes | kubelet metrics |
| 51820–51821 | UDP | all nodes | only if you switch flannel to WireGuard |
| 80, 443 | TCP | from the MetalLB range / tunnel | ingress-nginx |

**Port-security gotcha:** Neutron drops frames whose source MAC/IP is not bound to the
port. Overlay CNI (flannel VXLAN) is fine because pod traffic is encapsulated in the VM's
own IP. But **MetalLB VIPs are not** — you must add each VIP to the ports'
`allowed_address_pairs`, or MetalLB will announce an address that Neutron silently
discards. Same applies to any keepalived VIP:

```bash
for p in $(openstack port list --server k3s-server-1 -f value -c ID); do
  openstack port set --allowed-address ip-address=10.10.50.240/28 "$p"
done
```

---

## 6. Storage plan

Given ~50 TB delivered and a ~7.1 TiB working set (measured: MinIO 2.84 TiB, RocksDB
1.62 TiB, ClickHouse ~2.4 TB, everything else ~36 GiB combined).

| Pool | Media | Size | Redundancy | Consumer | Usable |
|---|---|---|---|---|---|
| **A. Ceph RBD (general)** | NVMe or SAS | 9 TB raw | 3× replica | Glance images, Nova root disks, self-service collaborator volumes | ~3 TB |
| **B. Ceph RGW (S3)** | SAS | 15 TB raw | EC 4+2 | backups: PG dumps, ES snapshots, ClickHouse `BACKUP TO S3`, MinIO mirror | ~10 TB |
| **C. Local NVMe, per sled** | NVMe RAID10 (PERC) | 20 TB usable | RAID10 in hardware | ClickHouse, RocksDB, MinIO data, Elasticsearch, Postgres, Kuzu | 20 TB |
| **D. Free reserve** | NVMe | ≥20% of pool C | — | ClickHouse merges, RocksDB compaction, ZFS/LVM breathing room | — |

Pool C is exposed to OpenStack as a **Cinder LVM backend on each compute host**:

```bash
# on each sled, over the PERC RAID10 virtual disk
pvcreate /dev/sdb
vgcreate cinder-nvme /dev/sdb
```

and in `globals.yml`:

```yaml
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-nvme"
```

**Pinning a volume to the same host as its VM.** Each `cinder-volume` service reports its
own backend, so create one volume type per sled and pin the DB VMs with host aggregates:

```bash
openstack volume type create nvme-sled1
openstack volume type set --property volume_backend_name=lvm-sled1 nvme-sled1
# repeat for sled2, sled3
```

Also enable Cinder's `InstanceLocalityFilter` so a volume can be scheduled onto the host
already running the instance. Accept the consequence honestly: **a VM with a local-NVMe
volume cannot live-migrate.** The DB VMs are pets; the light VMs on Ceph are cattle.

**Maximum-performance variant (optional).** For ClickHouse and RocksDB you can bypass the
virtio-blk path entirely by passing an NVMe namespace straight through to the guest with
vfio-pci and a Nova PCI alias (same mechanism as §11). You get bare-metal IOPS; you lose
snapshots, migration, and any Cinder management of that device. Reasonable for RocksDB
(immutable, re-derivable) — think hard before doing it to Postgres.

**Backups are still required.** Pool B is in the same chassis, the same room, and the same
failure domain. Keep the 22 TB `HSA` disk on `pc` as the off-box second copy; it already
holds the full migrated set, which makes it a working 3-2-1 leg for free.

---

## 7. Phase 1 — deploy host and base OS

### 7.1 Deploy host

```bash
# Ubuntu 24.04 on the deploy host
sudo apt update && sudo apt install -y git python3-dev python3-venv \
    libffi-dev gcc libssl-dev sshpass

sudo mkdir -p /opt/kolla && sudo chown "$USER" /opt/kolla
python3 -m venv /opt/kolla/venv
source /opt/kolla/venv/bin/activate
pip install -U pip
# pin ansible-core to the range the chosen Kolla release supports
pip install 'ansible-core>=2.16,<2.18'
pip install git+https://opendev.org/openstack/kolla-ansible@stable/2025.1
kolla-ansible install-deps
```

Generate an SSH key on the deploy host and push it to every node's `root` (or a sudo
user). Kolla-Ansible needs passwordless sudo on all targets.

### 7.2 Base OS on the sleds

Install Ubuntu 24.04 to the BOSS-N1 mirror on each sled. Use iDRAC virtual media for the
first one; for repeatability, stand up PXE (MAAS on the deploy host is the pleasant
option) and record MACs from §4.

Per-node prep:

```bash
# hostname & hosts entries must resolve consistently everywhere
hostnamectl set-hostname sled1
# disable cloud-init network management if you configure netplan yourself
# time sync is non-negotiable for Keystone tokens and Ceph
apt install -y chrony && systemctl enable --now chrony
# kernel cmdline for passthrough + huge pages (GRUB_CMDLINE_LINUX_DEFAULT)
#   intel_iommu=on iommu=pt default_hugepagesz=1G hugepagesz=1G hugepages=512
# 512 × 1 GB = 512 GB reserved for pinned guests on a 768 GB sled; tune per sled
update-grub && reboot
```

Verify after reboot:

```bash
grep -o 'intel_iommu=on' /proc/cmdline
grep Huge /proc/meminfo         # HugePages_Total should be 512
ls /sys/kernel/iommu_groups | wc -l   # non-zero
lscpu | grep -E 'NUMA node[0-9] CPU'  # note the ranges for pinning
```

> **Huge pages are a hard allocation.** RAM behind 1 GB pages is unavailable to the host
> page cache and to non-hugepage guests. Reserve what the pinned DB guests need and no
> more, or you will strand hundreds of gigabytes.

---

## 8. Phase 2 — Ceph via cephadm

Deploy Ceph *before* OpenStack; Kolla will consume it as external Ceph.

```bash
# on sled1
curl -sLO https://github.com/ceph/ceph/raw/quincy/src/cephadm/cephadm  # use the release you target
chmod +x cephadm && ./cephadm add-repo --release reef && ./cephadm install
cephadm bootstrap --mon-ip 10.10.40.11 \
  --cluster-network 10.10.41.0/24
ceph orch host add sled2 10.10.40.12
ceph orch host add sled3 10.10.40.13
ceph orch apply mon --placement="sled1,sled2,sled3"
ceph orch apply mgr --placement="sled1,sled2"
# OSDs: only the devices you allocated to pools A and B — NOT the cinder-nvme RAID10
ceph orch daemon add osd sled1:/dev/sdc
```

Pools and clients:

```bash
ceph osd pool create images 32 && rbd pool init images
ceph osd pool create volumes 64 && rbd pool init volumes
ceph osd pool create vms 64 && rbd pool init vms
ceph osd pool create backups 32 && rbd pool init backups

ceph auth get-or-create client.glance mon 'profile rbd' \
  osd 'profile rbd pool=images'
ceph auth get-or-create client.cinder mon 'profile rbd' \
  osd 'profile rbd pool=volumes, profile rbd pool=vms, profile rbd-read-only pool=images'
ceph auth get-or-create client.nova mon 'profile rbd' \
  osd 'profile rbd pool=vms, profile rbd pool=volumes'

# S3 endpoint for backups (pool B)
ceph orch apply rgw hcloud --placement="sled2,sled3"
```

Set `ceph osd crush` rules so pool B uses the SAS device class and pool A the NVMe class:

```bash
ceph osd crush rule create-replicated nvme-rule default host nvme
ceph osd pool set volumes crush_rule nvme-rule
```

Copy `ceph.conf` and the three keyrings into the Kolla config tree (§9.3).

---

## 9. Phase 3 — OpenStack via Kolla-Ansible

### 9.1 Inventory

```bash
source /opt/kolla/venv/bin/activate
sudo mkdir -p /etc/kolla && sudo chown "$USER" /etc/kolla
cp -r /opt/kolla/venv/share/kolla-ansible/etc_examples/kolla/* /etc/kolla/
cp /opt/kolla/venv/share/kolla-ansible/ansible/inventory/multinode /etc/kolla/inventory
kolla-genpwd            # writes /etc/kolla/passwords.yml — back this up, it is not regenerable
chmod 600 /etc/kolla/passwords.yml
```

Edit `/etc/kolla/inventory` per [Appendix B](#appendix-b--reference-inventory-files).

### 9.2 `globals.yml`

```yaml
---
kolla_base_distro: "ubuntu"
openstack_release: "2025.1"
kolla_internal_vip_address: "10.10.20.10"        # keepalived VIP on the API VLAN
kolla_external_vip_address: "10.10.50.10"
network_interface: "bond0.20"                    # host/API
api_interface: "bond0.20"
tunnel_interface: "bond0.30"                     # Geneve
storage_interface: "bond0.40"                    # Ceph public
neutron_external_interface: "bond0"              # provider/floating, untagged trunk
neutron_plugin_agent: "ovn"
neutron_global_physnet_mtu: 9000

kolla_enable_tls_internal: "yes"
kolla_enable_tls_external: "yes"
# put a real cert here; cert-manager cannot help you before the cluster exists
kolla_external_fqdn: "cloud.example.harvard.edu"

enable_horizon: "yes"
enable_skyline: "yes"                            # optional modern dashboard
enable_barbican: "yes"                           # secrets; Octavia needs it later
enable_octavia: "no"                             # revisit after K3s is stable
enable_heat: "yes"                               # optional; OpenTofu is used here instead
enable_prometheus: "yes"
enable_grafana: "yes"
enable_neutron_provider_networks: "yes"

# --- Ceph (external) ---
glance_backend_ceph: "yes"
cinder_backend_ceph: "yes"
nova_backend_ceph: "yes"
ceph_nova_pool_name: "vms"
ceph_cinder_pool_name: "volumes"
ceph_glance_pool_name: "images"

# --- local NVMe for databases ---
enable_cinder: "yes"
enable_cinder_backend_lvm: "yes"
cinder_volume_group: "cinder-nvme"

# --- host reservations ---
nova_reserved_host_memory_mb: 16384
nova_cpu_allocation_ratio: 1.0                   # no CPU oversubscription on a DB platform
nova_ram_allocation_ratio: 1.0                   # never oversubscribe RAM under databases
```

> `nova_ram_allocation_ratio: 1.0` is deliberate. The default oversubscribes memory, which
> is fine for idle developer VMs and catastrophic under ClickHouse.

### 9.3 Ceph credentials into Kolla

```bash
mkdir -p /etc/kolla/config/{glance,cinder/cinder-volume,cinder/cinder-backup,nova}
cp ceph.conf /etc/kolla/config/glance/
cp ceph.client.glance.keyring /etc/kolla/config/glance/
cp ceph.conf ceph.client.cinder.keyring /etc/kolla/config/cinder/cinder-volume/
cp ceph.conf ceph.client.nova.keyring /etc/kolla/config/nova/
```

### 9.4 Deploy

```bash
kolla-ansible -i /etc/kolla/inventory bootstrap-servers
kolla-ansible -i /etc/kolla/inventory prechecks     # fix everything it complains about
kolla-ansible -i /etc/kolla/inventory deploy
kolla-ansible -i /etc/kolla/inventory post-deploy   # writes /etc/kolla/clouds.yaml + admin-openrc.sh
pip install python-openstackclient
source /etc/kolla/admin-openrc.sh
openstack service list && openstack hypervisor list
```

Commit `/etc/kolla/globals.yml`, the inventory, and any `config/` overrides to git —
**never** `passwords.yml` or the keyrings. Add them to `.gitignore` alongside
`docs/Secretes/`.

---

## 10. Phase 4 — flavors, images, aggregates, performance

### 10.1 Image

```bash
wget https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
openstack image create ubuntu-24.04 --disk-format qcow2 --container-format bare \
  --public --property hw_scsi_model=virtio-scsi \
  --property hw_disk_bus=scsi --property hw_qemu_guest_agent=yes \
  --file noble-server-cloudimg-amd64.img
```

### 10.2 Host aggregates

```bash
openstack aggregate create --zone nova db-sleds
openstack aggregate add host db-sleds sled1
openstack aggregate add host db-sleds sled2
openstack aggregate set --property db_capable=true db-sleds

openstack aggregate create --zone nova gpu
openstack aggregate add host gpu gpu1
openstack aggregate set --property gpu=true gpu
```

### 10.3 Flavors

| Flavor | vCPU | RAM | Root | Extra specs | Used by |
|---|---|---|---|---|---|
| `k3s.server` | 8 | 32 GB | 100 GB (Ceph) | pinned, 1 NUMA node | 3× K3s server (etcd) |
| `k3s.db.xl` | 48 | 512 GB | 100 GB + local NVMe volume | pinned, 1 GB huge pages, isolate | ClickHouse, RocksDB |
| `k3s.agent` | 24 | 192 GB | 100 GB (Ceph) | pinned | MinIO, ES, API, workers |
| `k3s.gpu` | 16 | 128 GB | 100 GB (Ceph) | PCI alias `l40s:1` | GPU workloads |
| `lab.small` / `lab.medium` | 2 / 8 | 8 / 32 GB | 40 / 100 GB (Ceph) | default (shared CPU) | collaborator self-service |

```bash
openstack flavor create k3s.db.xl --vcpus 48 --ram 524288 --disk 100
openstack flavor set k3s.db.xl \
  --property hw:cpu_policy=dedicated \
  --property hw:cpu_thread_policy=prefer \
  --property hw:mem_page_size=1GB \
  --property hw:numa_nodes=2 \
  --property hw:emulator_threads_policy=share \
  --property aggregate_instance_extra_specs:db_capable=true

openstack flavor create k3s.server --vcpus 8 --ram 32768 --disk 100
openstack flavor set k3s.server \
  --property hw:cpu_policy=dedicated --property hw:numa_nodes=1

openstack flavor create lab.medium --vcpus 8 --ram 32768 --disk 100   # no pinning: oversubscribable
```

### 10.4 Compute-host tuning that actually matters

On each compute node, in `/etc/kolla/config/nova/nova-compute.conf`:

```ini
[compute]
cpu_dedicated_set = 12-63,76-127     # leave 0-11,64-75 to the host & control plane
cpu_shared_set = 4-11,68-75

[libvirt]
images_type = rbd
disk_cachemodes = "network=writeback,file=none,block=none"
hw_disk_discard = unmap
virt_type = kvm
cpu_mode = host-passthrough
num_pcie_ports = 16
```

Then `kolla-ansible reconfigure -i /etc/kolla/inventory --tags nova`.

Also apply the `cpu-partitioning` tuned profile so the host stops scheduling its own work
on pinned cores:

```bash
apt install -y tuned
echo "isolated_cores=12-63,76-127" > /etc/tuned/cpu-partitioning-variables.conf
tuned-adm profile cpu-partitioning && reboot
```

**Why each setting earns its place:**

- `cpu_dedicated_set` — without it, pinned guests can land on the cores running MariaDB
  and OVN, and your control plane stutters under ClickHouse load.
- `disk_cachemodes … block=none` — host-side caching of guest block I/O double-caches
  data the guest already caches, wasting the RAM you bought and risking write ordering.
- `cpu_mode = host-passthrough` — exposes AVX-512/AMX to guests. Requires identical CPUs
  for live migration (they are, within a sled generation).
- `hw:emulator_threads_policy=share` — keeps qemu's emulator threads off the pinned vCPUs.

---

## 11. Phase 5 — GPU passthrough

Nova cannot time-share an L40S without vGPU licensing, so pass whole cards through.
Four L40S = four GPU-capable VMs maximum, one card each (or one VM with several).

```bash
# on gpu1: find the addresses and bind to vfio
lspci -nn | grep -i nvidia
# 41:00.0 3D controller [0302]: NVIDIA Corporation AD102GL [L40S] [10de:26b9]
cat >/etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=10de:26b9
EOF
echo vfio-pci > /etc/modules-load.d/vfio-pci.conf
update-initramfs -u && reboot
lspci -nnk -s 41:00.0 | grep 'Kernel driver'   # must say vfio-pci
```

`/etc/kolla/config/nova/gpu1/nova-compute.conf`:

```ini
[pci]
device_spec = {"vendor_id":"10de","product_id":"26b9"}
alias = {"vendor_id":"10de","product_id":"26b9","device_type":"type-PCI","name":"l40s","numa_policy":"preferred"}
```

`/etc/kolla/config/nova/nova-scheduler.conf` on the controllers needs the same `alias`
block, then:

```bash
kolla-ansible reconfigure -i /etc/kolla/inventory --tags nova
openstack flavor create k3s.gpu --vcpus 16 --ram 131072 --disk 100
openstack flavor set k3s.gpu \
  --property "pci_passthrough:alias"="l40s:1" \
  --property hw:cpu_policy=dedicated \
  --property hw:numa_nodes=1 \
  --property aggregate_instance_extra_specs:gpu=true
```

Inside the guest: install the NVIDIA data-center driver, then in K3s install the
**NVIDIA GPU Operator** with `driver.enabled=false` (the driver is in the guest image)
plus the container toolkit and device plugin. Taint the node
`nvidia.com/gpu=true:NoSchedule` so only GPU workloads land there.

Caveats to accept: no live migration of a passthrough VM; the card is unavailable to the
host; and a guest reboot occasionally needs a `FLR`-capable device (the L40S is).

---

## 12. Phase 6 — collaborator self-service

This is the reason the layer exists, so make it a real service, not an afterthought.

### 12.1 Domains, projects, roles

```bash
openstack domain create hsph
openstack project create --domain hsph --description "HCloud platform (K3s)" hcloud-platform
openstack project create --domain hsph --description "Lab: Smith" lab-smith
openstack user create --domain hsph --password-prompt asmith
openstack role add --project lab-smith --user asmith member
openstack role add --project lab-smith --user asmith load-balancer_member   # if Octavia later
# a read-only auditor role for yourself in every project
openstack role add --project lab-smith --user hzhou reader
```

### 12.2 Quotas — publish the table, don't negotiate per request

| Tier | vCPU | RAM | Volumes | Storage | Floating IPs | Instances |
|---|---|---|---|---|---|---|
| `sandbox` (teaching) | 8 | 32 GB | 4 | 200 GB | 0 | 4 |
| `lab-small` | 32 | 128 GB | 8 | 2 TB | 2 | 8 |
| `lab-large` | 96 | 512 GB | 16 | 6 TB | 4 | 16 |
| `hcloud-platform` | rest | rest | — | pool C | 4 | — |

```bash
openstack quota set --cores 32 --ram 131072 --instances 8 \
  --volumes 8 --gigabytes 2048 --floating-ips 2 --secgroups 10 lab-smith
```

Keep the platform project's own quota generous but **bounded** — a runaway `hcloud-platform`
must not be able to starve every lab.

### 12.3 Federated login (match the NERC experience)

Collaborators should not get a separate password. Configure Keystone federation via
OpenID Connect to your IdP (**HarvardKey** or **CILogon**, which the NERC project already
used), with `mod_auth_openidc` in front of Keystone:

1. Register an OIDC client with the IdP; note client id/secret and the discovery URL.
2. Put the Apache/`mod_auth_openidc` config into
   `/etc/kolla/config/keystone/wsgi-keystone.conf` and the OIDC secret into
   `passwords.yml`-adjacent secret files.
3. Create the mapping and protocol:

```bash
openstack identity provider create harvardkey --remote-id https://login.example.harvard.edu
openstack mapping create harvardkey-map --rules mapping.json
openstack federation protocol create openid --identity-provider harvardkey \
  --mapping harvardkey-map
```

`mapping.json` maps IdP group claims → OpenStack projects/roles, so onboarding a lab
member becomes an IdP group change rather than a ticket to you.

4. Enable `websso` in Horizon so the dashboard shows an institutional login button.

Until federation is working, use local Keystone users — it is a supported permanent
fallback, not a blocker.

### 12.4 What collaborators get

- **Horizon** (and optionally Skyline) at `https://cloud.example.harvard.edu`
- Launch/stop/resize VMs, key pairs, security groups, floating IPs, volumes, snapshots
- **Application credentials** for scripting (`openstack application credential create`) —
  teach this instead of sharing passwords
- Published images: Ubuntu 24.04, Rocky 9, and a Windows image if licensing permits
- Their own quota, visible in the dashboard, so capacity conversations are factual

Write a short `docs/COLLABORATOR-GUIDE.md` covering login, launching a VM, SSH, quotas,
and the support boundary ("we run the cloud; you run your VM"). Without it, self-service
becomes a help desk staffed by you.

---

## 13. Phase 7 — the K3s cluster on OpenStack VMs

### 13.1 Topology (and the one mistake that matters)

| VM | Flavor | Host | Role | Storage |
|---|---|---|---|---|
| `k3s-server-1..3` | `k3s.server` | sled1, sled2, sled3 — **anti-affinity** | K3s server, embedded etcd | Ceph root + small NVMe volume for etcd |
| `k3s-db-ch` | `k3s.db.xl` | sled1 | ClickHouse | local NVMe, 8 TB |
| `k3s-db-rocks` | `k3s.db.xl` | sled2 | RocksDB, Kuzu | local NVMe, 6 TB |
| `k3s-agent-1..2` | `k3s.agent` | sled2, sled3 | MinIO, Elasticsearch ×2, Postgres, api-cache, higlass | local NVMe, 6 TB |
| `k3s-gpu-1` | `k3s.gpu` | gpu1 | GPU workloads | Ceph root |

> **The three K3s servers must be on three different sleds.** Etcd tolerates one member
> loss out of three; two members on one sled means a single sled reboot destroys quorum
> and the whole cluster with it. Enforce it in OpenStack, not by hand:

```bash
openstack server group create --policy anti-affinity k3s-servers
```

> **Etcd is fsync-latency-sensitive.** Give each server VM its etcd directory on a
> **local NVMe volume**, not on Ceph. Target `etcd_disk_wal_fsync_duration_seconds` p99
> under 10 ms; Ceph-backed etcd under load will exceed that and produce leader elections
> that look like random cluster outages.

### 13.2 Declare the VMs (OpenTofu/Terraform)

`infra/openstack/main.tf`:

```hcl
terraform {
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = "~> 3.0" }
  }
}
provider "openstack" { cloud = "hcloud" }   # from /etc/openstack/clouds.yaml

resource "openstack_compute_servergroup_v2" "servers" {
  name     = "k3s-servers"
  policies = ["anti-affinity"]
}

resource "openstack_networking_network_v2" "k3s" { name = "k3s-net" }

resource "openstack_networking_subnet_v2" "k3s" {
  name            = "k3s-subnet"
  network_id      = openstack_networking_network_v2.k3s.id
  cidr            = "192.168.30.0/24"
  dns_nameservers = ["10.10.20.1"]
  # MTU comes from the network; do not set it in the guest
}

resource "openstack_compute_instance_v2" "server" {
  count           = 3
  name            = "k3s-server-${count.index + 1}"
  image_name      = "ubuntu-24.04"
  flavor_name     = "k3s.server"
  key_pair        = "hcloud-admin"
  security_groups = ["k3s-nodes"]
  user_data       = templatefile("cloud-init/server.yaml", {
    index = count.index, token = var.k3s_token
  })
  scheduler_hints { group = openstack_compute_servergroup_v2.servers.id }
  network { uuid = openstack_networking_network_v2.k3s.id }
}
```

Keep `var.k3s_token` out of git (use `TF_VAR_k3s_token` from a file under
`docs/Secretes/`). Store state on the RGW S3 endpoint so it survives the deploy host.

### 13.3 First server

```bash
curl -sfL https://get.k3s.io | INSTALL_K3S_CHANNEL=stable sh -s - server \
  --cluster-init \
  --token "$K3S_TOKEN" \
  --tls-san k3s.hcloud.internal \
  --tls-san 10.10.50.20 \
  --node-taint "node-role.kubernetes.io/control-plane=true:NoSchedule" \
  --disable traefik \
  --disable servicelb \
  --flannel-iface ens3 \
  --etcd-snapshot-schedule-cron "0 */6 * * *" \
  --etcd-snapshot-retention 20 \
  --etcd-s3 --etcd-s3-endpoint <rgw-endpoint> --etcd-s3-bucket k3s-etcd \
  --kubelet-arg "cloud-provider=external"
```

Servers 2 and 3: identical, with `--server https://<server-1-ip>:6443` in place of
`--cluster-init`.

Agents:

```bash
curl -sfL https://get.k3s.io | K3S_URL="https://k3s.hcloud.internal:6443" \
  K3S_TOKEN="$K3S_TOKEN" sh -s - agent \
  --node-label "hcloud.role=db" \
  --flannel-iface ens3 \
  --kubelet-arg "cloud-provider=external"
```

Notes on the flags:

- `--disable traefik` — ingress-nginx is what the converted manifests target.
- `--disable servicelb` — MetalLB handles `LoadBalancer` (or Octavia later); running both
  produces confusing double-allocation.
- `--kubelet-arg cloud-provider=external` — **required** before the OpenStack CCM can
  initialize nodes. Without it, nodes come up without provider IDs and Cinder CSI
  attachment fails in a way whose error message points nowhere useful.
- Etcd snapshots to S3 (Ceph RGW) — the single highest-value backup in this whole design.
- Verify flannel MTU: `ip link show flannel.1` should read ≈8892 on a 9000 underlay.

---

## 14. Phase 8 — Kubernetes/OpenStack integration

### 14.1 Application credential + `cloud.conf`

```bash
openstack application credential create k3s-ccm --role member --unrestricted
kubectl create secret -n kube-system generic cloud-config --from-file=cloud.conf
```

```ini
[Global]
auth-url=https://cloud.example.harvard.edu:5000/v3
application-credential-id=<id>
application-credential-secret=<secret>
region=RegionOne
[BlockStorage]
bs-version=v3
ignore-volume-az=true
[LoadBalancer]
enabled=false            # MetalLB does this; flip to true when Octavia arrives
```

### 14.2 Cloud controller manager + Cinder CSI

```bash
helm repo add cpo https://kubernetes.github.io/cloud-provider-openstack
helm install ccm cpo/openstack-cloud-controller-manager -n kube-system
helm install cinder-csi cpo/openstack-cinder-csi -n kube-system
kubectl get nodes -o jsonpath='{.items[*].spec.providerID}'   # must show openstack://...
```

Storage classes:

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: cinder-ceph            # general-purpose, replicated, movable
provisioner: cinder.csi.openstack.org
parameters: { type: __DEFAULT__ }
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-nvme             # databases: raw speed, node-pinned
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
```

Point the `local-path` provisioner at the mounted local-NVMe Cinder volume inside each DB
VM (e.g. `/var/lib/hcloud/hot`) via its ConfigMap, one `nodePathMap` entry per node.

**Keep the NERC StorageClass name working.** `scripts/64-storage-parity.sh` already
creates an alias for `ocs-external-storagecluster-ceph-rbd`; point that alias at
`cinder-ceph` so unmodified manifests apply.

### 14.3 MetalLB, ingress, TLS, tunnel

```bash
helm install metallb metallb/metallb -n metallb-system --create-namespace
# IPAddressPool from the floating-IP range, and see §5: add every VIP to
# allowed_address_pairs on the node ports or announcements are silently dropped
helm install ingress-nginx ingress-nginx/ingress-nginx -n ingress-nginx --create-namespace \
  --set controller.service.type=LoadBalancer
helm install cert-manager jetstack/cert-manager -n cert-manager --create-namespace \
  --set crds.enabled=true
```

Cloudflare Tunnel and cert-manager DNS-01 are unchanged from the existing scripts
(`62-cloudflared-tunnel.sh`, `63-cert-manager.sh`) — the tunnel now runs as a pod in a VM
instead of on bare metal, which it neither knows nor cares about.

---

## 15. Phase 9 — migrate the NERC stack

The migration path does not change. The repo's scripts still apply:

1. `scripts/30-export-nerc.sh` — export `favor-4ee4be` (already done).
2. `scripts/50-convert-manifests.py` — Routes → Ingress, `local-path`/`cinder-ceph`.
3. Apply structure with `replicas: 0`.
4. Copy data — `60/61-migrate-*.sh`, `68-rsync-nerc-data.sh`, plus
   `62-resume-bigvol-skip.sh` / `63-resume-until-done.sh`.
5. Delta-sync, `scripts/69-scale-up.sh`, rotate NERC tokens.

### PVC → storage class placement

| PVC | Size today | StorageClass | Node |
|---|---|---|---|
| `data-hg38-clickhouse-0` | ~2.4 TB | `local-nvme` | `k3s-db-ch` |
| `hg38-rocksdb` | 1.62 TiB | `local-nvme` | `k3s-db-rocks` |
| `minio-pvc` | 2.84 TiB | `local-nvme` | `k3s-agent-1` |
| `elasticsearch-data-*-0/1` | ~4 GiB | `local-nvme` | `k3s-agent-1`, `k3s-agent-2` (different nodes) |
| `data-postgres-0` | ~1 GiB | `cinder-ceph` | any — small enough that replication is free |
| `kuzu-data-api-0` | 26 GiB | `local-nvme` | `k3s-db-rocks` |
| `higlass-data`, `api-cache-api-0` | ~6 GiB | `cinder-ceph` | any |

### One sequencing rule

**Do not copy 7 TB twice.** The ~7.1 TiB already sitting on `/media/hzhou/HSA/Sync/HCloud/cluster-data`
(MinIO, RocksDB, Kuzu, Postgres, higlass, api-cache complete; ClickHouse ~87%) is the
staging copy. Bring OpenStack + K3s up **empty**, validate it end to end, and only then
rsync from HSA into the new PVCs and perform the ClickHouse cutover quiesce. If you push
data in before the platform is validated, you will migrate it again.

---

## 16. Day-2 operations

| Concern | Practice |
|---|---|
| **OpenStack config backup** | `/etc/kolla/{globals.yml,inventory,passwords.yml,config/}` — `passwords.yml` is **not** regenerable; losing it means redeploying |
| **Control-plane DB backup** | `kolla-ansible mariadb_backup --full` weekly, `--incremental` daily, off-box |
| **Keystone fernet keys** | rotate on schedule (Kolla does this); back up the repository or all tokens invalidate |
| **Ceph** | `ceph -s` green; watch `nearfull` at 80%; test a drive replacement once, deliberately, before one fails |
| **K3s etcd** | 6-hourly snapshots to RGW S3 (§13.3); practice a restore |
| **Monitoring** | Kolla's Prometheus/Grafana for infra; kube-prometheus-stack inside K3s for workloads; Ceph mgr dashboard. Alert on: etcd fsync p99, Ceph health, hypervisor RAM, NVMe wear (`smartctl`), iDRAC hardware events |
| **Upgrades** | OpenStack: SLURP-to-SLURP once a year (`kolla-ansible upgrade`), staging first. K3s: patch monthly, minor quarterly, one minor at a time. Ceph: after OpenStack, never simultaneously |
| **Capacity** | monthly review of `openstack hypervisor stats show` and per-project quota usage; the honest signal for "buy another sled" |
| **Change control** | everything in this repo: `globals.yml`, inventory, Terraform, Helm values. Nothing configured only in Horizon |

---

## 17. Risk register + rollback

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| DB performance regression vs bare metal | high | medium | local NVMe (§6), huge pages + pinning (§10), `cache=none`, no RAM oversubscription. **Benchmark before migrating data** (§19) |
| OpenStack control-plane outage takes down the K3s API | medium | high | running VMs survive a control-plane outage; only *management* stops. Keep controllers on 3 hosts; test by stopping controller containers on one sled |
| Etcd quorum loss from co-located servers | medium | **critical** | server group anti-affinity, enforced in Terraform (§13.1) |
| Etcd latency on Ceph-backed disks | high | high | etcd on local NVMe; alert on fsync p99 |
| MTU mismatch (Geneve + VXLAN) | high | medium | the three-level MTU plan and ping tests in §5/§19 |
| MetalLB VIP dropped by Neutron port security | high | medium | `allowed_address_pairs` (§5) |
| Huge pages strand RAM | medium | medium | reserve only what pinned flavors consume; review `HugePages_Free` monthly |
| OpenStack upgrade breaks the platform | medium | high | SLURP releases only; snapshot controllers; upgrade a staging deploy first |
| Operator bandwidth (one person, two platforms) | **high** | high | automate in this repo; consider paying for supported OpenStack, or Appendix A |
| Firmware drift across sleds | medium | medium | OME-M firmware baseline (§4) |

### Rollback to bare-metal K3s

Keep this viable for the first 90 days:

1. `scripts/40-install-rke2.sh` (and the K3s equivalent) are unchanged and target bare metal.
2. The full staging copy of the data remains on `HSA` on `pc` — do not delete it after cutover.
3. Because all PVs of consequence are `local-path` on NVMe, the rollback is: reinstall a
   sled bare metal, install K3s, apply the same converted manifests, rsync from HSA.
4. **Decision gate:** if §19's benchmarks show >25% ClickHouse/RocksDB regression that
   tuning cannot close, roll back the platform layer and keep OpenStack on one sled purely
   for collaborator VMs. That hybrid keeps the self-service goal and gives the databases
   bare metal — see Appendix A.

---

## 18. Effort and sequencing

| Phase | Work | First-time estimate |
|---|---|---|
| 0 — physical/firmware/BIOS | §4 | 2–3 days |
| 1 — deploy host + base OS | §7 | 2–3 days |
| 2 — Ceph | §8 | 3–5 days |
| 3 — OpenStack deploy | §9 | 1–2 weeks (most of the learning curve lands here) |
| 4–5 — flavors, tuning, GPU | §10–11 | 3–5 days |
| 6 — self-service, federation | §12 | 1 week (federation is the slow part) |
| 7–8 — K3s + integration | §13–14 | 3–5 days |
| 9 — data migration + cutover | §15 | 3–5 days + the ClickHouse quiesce window |
| **Total** | | **6–9 weeks** |

For comparison, bare-metal K3s on the same hardware is roughly 2–3 days to a running
cluster. The difference is the price of the self-service layer; budget it explicitly
rather than discovering it.

Suggested order that de-risks the most: **Phase 0–3 on one sled first**
(all-in-one Kolla, `enable_ceph` deferred, no tenants) to learn the tooling and burn the
first round of mistakes, then wipe and deploy the real 3-controller layout.

---

## 19. Validation checklist

Run every item before migrating data. Each has a specific failure it catches.

**Infrastructure**

- [ ] `openstack hypervisor list` shows all compute hosts `up`
- [ ] `ceph -s` = `HEALTH_OK`; a deliberate OSD stop recovers without data loss
- [ ] `ping -M do` passes at full MTU host→host, VM→VM, and pod→pod (§5)
- [ ] Boot a VM in each aggregate; confirm `virsh dumpxml` shows the expected pinning,
      huge pages, and NUMA topology
- [ ] Live-migrate a Ceph-backed VM successfully; confirm a local-NVMe VM correctly refuses
- [ ] Reboot one controller sled: API returns, no workload VM is lost
- [ ] Kill the whole control plane (`docker stop` on all three): running VMs keep serving

**Performance (the gate for §17's rollback decision)**

- [ ] `fio --name=rand --rw=randread --bs=4k --iodepth=64 --numjobs=8 --direct=1` inside
      a DB VM on local NVMe vs on the bare host — record the ratio; expect ≥85%
- [ ] ClickHouse benchmark on a real query set vs the `pc` PoC numbers
- [ ] `iperf3` between VMs on different sleds — expect ≥80% of wire speed
- [ ] etcd `wal_fsync_duration_seconds` p99 < 10 ms under load

**Kubernetes**

- [ ] `kubectl get nodes -o wide` — all nodes `Ready`, `providerID` set to `openstack://`
- [ ] PVC on `cinder-ceph` binds, attaches, survives a pod reschedule
- [ ] PVC on `local-nvme` binds and pins to the right node
- [ ] `LoadBalancer` Service gets an IP and is reachable from the LAN
- [ ] cert-manager issues a real certificate; Cloudflare Tunnel serves it publicly
- [ ] Etcd snapshot restore rehearsed on a throwaway cluster

**Self-service**

- [ ] A test collaborator logs in via the IdP, launches a VM, attaches a floating IP,
      SSHes in, and hits their quota wall gracefully
- [ ] That collaborator provably **cannot** see or touch `hcloud-platform` resources
- [ ] Quota exhaustion produces a clear dashboard error, not a stuck `BUILD`

---

## Appendix A — cheaper ways to get the same self-service

Recorded for the six-month review, not to relitigate the decision.

| Option | Gives you | Costs |
|---|---|---|
| **KubeVirt on bare-metal K3s** | VMs as Kubernetes objects, per-namespace quotas/RBAC, live migration, Windows guests | no Horizon-style dashboard (the KubeVirt UI is thinner), collaborators need `kubectl` or a portal you build; databases stay on bare metal at full speed |
| **Harvester (SUSE)** | a real VM dashboard, HCI, Rancher integration, K8s underneath | Harvester owns the storage layer (Longhorn), so DB volumes lose direct NVMe |
| **Hybrid: OpenStack on 1–2 sleds, bare-metal K3s on the rest** | full self-service IaaS for collaborators **and** full-speed databases | two platforms to operate, static split of capacity |
| **Full OpenStack + K3s on top (this document)** | one management plane, maximum flexibility, hard multi-tenancy | ~20% RAM, ~15% storage after replication, 6–9 weeks, ongoing OpenStack ops |

The **hybrid** is the strongest fallback if the §19 performance gate fails: keep this
document's Phases 0–6 on a subset of the hardware for collaborator VMs, and run the
migrated NERC stack on bare-metal K3s per `docs/HARDWARE.md`.

---

## Appendix B — reference inventory files

`/etc/kolla/inventory` (abbreviated to the groups you must edit):

```ini
[control]
sled1 ansible_host=10.10.20.11
sled2 ansible_host=10.10.20.12
sled3 ansible_host=10.10.20.13

[network]
sled1
sled2
sled3

[compute]
sled1
sled2
sled3
gpu1 ansible_host=10.10.20.14

[storage]
sled1
sled2
sled3

[monitoring]
sled1

[deployment]
localhost ansible_connection=local
```

Per-host Nova overrides live at `/etc/kolla/config/nova/<hostname>/nova-compute.conf`,
which is how `gpu1` gets its PCI `device_spec` without affecting the other sleds.

Suggested repo layout for everything this document creates:

```
infra/
  openstack/           # OpenTofu: networks, VMs, server groups, security groups
  kolla/               # globals.yml, inventory, config/ overrides  (NO passwords.yml)
  cloud-init/          # server.yaml, agent.yaml
  helm/                # values for ccm, cinder-csi, metallb, ingress-nginx
docs/
  K3s-OS-VM.md         # this file
  COLLABORATOR-GUIDE.md
  HARDWARE.md
```

---

*Author: zhouhufeng <zhouhufeng@gmail.com> — sole author and maintainer.*
