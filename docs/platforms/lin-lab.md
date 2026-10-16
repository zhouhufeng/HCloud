# Platform: Lin Lab 4-node cluster — OpenStack on the nodes, K3s in the VMs

**Source of the hardware and cost:** the genohub.org discussion
[*Cloud infrastructure*](https://discussion.genohub.org/t/cloud-infrastructure/290) (posted
2026-10-16). Treat that post as the final hardware record; this page turns it into a platform.

**Where this sits in HCloud:** this is a *hosting platform*. The four nodes run OpenStack
(`platform/openstack/` creates the VMs); the K3s middleware in `hcloud/` runs inside those
VMs unchanged. Nothing in `hcloud/` or `apps/` is specific to these nodes.

## 1. Hardware (per the post)

| Component | Per node | 4 nodes |
|---|---|---|
| CPU | 2× 64-core Intel Xeon (696X-class) — 128 cores / 256 threads | 512 cores / 1,024 threads |
| RAM | 512 GB DDR5 ECC RDIMM (16× 32 GB) | 2 TB |
| Boot | 2× 2 TB PCIe Gen4 NVMe — boot only | 16 TB NVMe (boot only) |
| Bulk | 12× 14 TB SAS enterprise HDD — all data storage | 168 TB per node, **672 TB raw** |
| Network | Dual 10 GbE onboard | — |
| Chassis | 4U rackmount, 12–24 bays, dual-socket board, redundant 1600 W PSUs, rack fans, rails | — |

**Cost (post):** hardware ≈ $30,650 per node, $122,600 total; integration, burn-in, and a 3–5 year
warranty add $26,000; estimated total **$148,600**.

### 1.1 Storage layout (confirmed)

- **Capacity:** 12 × 14 TB = **168 TB per node, 672 TB raw** across four nodes. The post's "150 TB" and
  "600 TB" figures are superseded.
- **Usable capacity** after RAID-6 or erasure coding is about 400–450 TB, per the post.
- **NVMe is boot only** (2 × 2 TB per node, mirrored). **All data storage is on HDD.** No NVMe is
  available for databases, etcd, or Ceph journals.

## 2. Topology

| Node | OpenStack role | K3s VM |
|---|---|---|
| lin-1 | controller + compute | `k3s-server-1` (`HCLOUD_HA=true`, `--cluster-init`) |
| lin-2 | controller + compute | `k3s-server-2` (joins with `HCLOUD_SERVER_URL`) |
| lin-3 | controller + compute | `k3s-server-3` (joins) |
| lin-4 | compute | `k3s-agent-1` (agent, no etcd) |

Three K3s servers give etcd quorum and fit the Terraform server group's anti-affinity: one server per
node, so losing a node does not lose etcd. The fourth node carries the agent VM. OpenStack
controller services on lin-1..3 are an assumption to confirm, not a fact from the post.

**Open topology decisions:** a stable API address for the three servers (a DNS name over all three
or a VIP) belongs in `HCLOUD_TLS_SAN`; without one, a joiner that points at `lin-1` stops working if
`lin-1` is down. The post has no decision on this.

## 3. Bring-up

```bash
# OpenStack on the four nodes: done outside this repo (see §4 for the runbook gaps)
tofu -chdir=platform/openstack init && tofu -chdir=platform/openstack apply

# on each VM (ssh): platform/linux/10-host-prep.sh, then hcloud/10-install-k8s.sh
#   server 1: HCLOUD_HA=true
#   servers 2-3: HCLOUD_NODE_ROLE=server, HCLOUD_SERVER_URL=https://<server-1>:6443
#   agent:    HCLOUD_NODE_ROLE=agent,     HCLOUD_SERVER_URL=https://<server-1>:6443
#   all:      HCLOUD_K8S_EXTRA_ARGS="--flannel-iface <10GbE iface> --kubelet-arg cloud-provider=external"
# from server 1: hcloud/11..15, then
bash platform/openstack/20-cloud-integration.sh
```

Checks: `kubectl get nodes` shows 3 servers and 1 agent Ready; `kubectl get sc` shows
`local-path` (default), `hcloud-data`, and `ocs-external-storagecluster-ceph-rbd`.

## 4. Gaps against the existing runbook

`docs/platforms/openstack.md` was written for the MX7000 design and needs these changes for the Lin Lab
hardware:

- **Database and etcd storage.** The runbook keeps etcd and database PVs on host-local NVMe (RAID10). The
  Lin Lab nodes have no such NVMe, so etcd and every database (ClickHouse, Postgres, Elasticsearch, RocksDB,
  Kuzu) run on the HDD pool. HDD fsync latency is a risk for etcd and for random-I/O databases. Test it
  before the production cutover.
- **Ceph.** The runbook places Ceph MON/MGR/OSD on the sleds. Here the OSDs sit on the 12 HDD per node, and
  the NVMe boot drives are not Ceph media. Confirm the OSD layout before running §8 of the runbook.
- **Memory budget.** At 512 GB per node, the runbook's 768 GB sleds have 50% less. The capacity budget in
  the runbook (§2) must be recomputed. The post says 512 GB may be low for large in-memory analytics.
- **Cooling and power.** The post flags 128 cores per node and redundant power as needing checks at install.

## 5. Public serving and tenants

Unchanged from the middleware: cloudflared inside the cluster, `HCLOUD_DOMAIN` and the wildcard
certificate, and per-user quotas from `hcloud/14-tenants.sh`. The example quota defaults in
`hcloud/hcloud.env.example` are sized for a 31 GiB desktop, not 512 cores. Raise them before onboarding users.

---
*Author: zhouhufeng <zhouhufeng@gmail.com> — sole author and maintainer.*
