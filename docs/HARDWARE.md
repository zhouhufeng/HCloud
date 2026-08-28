# HCloud — Official Platform Purchasing Summary ($150,000 + $50,000)

The official HCloud version runs on **purchased Dell server blades plus a storage
rack**, under **K3s** (not OpenShift). It must run the **entire** NERC-equivalent stack
(ClickHouse, 2× Elasticsearch, MinIO, RocksDB, Postgres/pgvector, Kuzu, API + workers)
concurrently, serve the public site 24/7, and take on GPU/AI workloads. Sized from the
real workload: ~7–8 TiB of data and RAM-/IOPS-hungry databases.

| Budget line | Amount |
|---|---|
| Dell server blades + storage rack (hardware, 5-yr support) | **$150,000** |
| AI tooling & software (credits, seats, licenses) | **$50,000** |
| **Total** | **$200,000** |

**Two decisive factors:** **RAM** (what blocks the full stack on the 31 GiB PoC box)
and **fast NVMe storage** (ClickHouse/ES/RocksDB do heavy random I/O — a spinning HDD
is the bottleneck). ECC memory and drive redundancy are mandatory for a 24/7 platform.

---

## Hardware — Dell blade chassis + storage rack (≈$150,000)

| Component | Spec | Notes |
|---|---|---|
| Chassis | **Dell PowerEdge MX7000** modular enclosure (7U) + rails | blade backplane, shared power/fabric, single management plane |
| Compute blades | **3–4× MX750c sleds**, each 2× Xeon Scalable (Gold) — 32–64 cores per sled | K3s server + agent nodes; adding a sled adds a node |
| RAM | **512 GB–1 TB DDR5 ECC RDIMM per sled → 2–3 TB aggregate** | full stack + OS page-cache for the multi-TB datasets |
| GPU | **GPU sled or PowerEdge R760xa** → up to 4× NVIDIA **L40S / RTX 6000 Ada** | AlphaGenome/ML and AI-tooling workloads |
| Boot | **BOSS-N1 per sled: 2× 480 GB M.2 NVMe, RAID1** | mirrored OS, separate from data |
| Database storage | **Storage rack: 16–24× 3.84 TB U.2/E3.S NVMe, hot-swap, RAID10** (PERC H965i or ZFS) → **~30–45 TB usable** | ClickHouse/ES/RocksDB/Postgres/Kuzu |
| Bulk / object + backup | **Dell ME5 array or SAS JBOD: 12–24× 8–20 TB SAS** → ~150–300 TB raw | MinIO bulk objects + backup target |
| Fabric / network | **MX9116n fabric switching engine**, dual **25/100 GbE** uplinks | east-west blade traffic + public serving, redundant |
| Management | **iDRAC9 Enterprise** per sled + **OpenManage Enterprise-Modular** | remote KVM/power — essential lights-out |
| Power | chassis **redundant PSUs (N+N)**, dual PDU feeds | pair with rack UPS |
| Warranty | **ProSupport, 5-year** on chassis, sleds, storage | production support window |

**Tiers within the budget:** *Ideal* — 4 sleds, ~3 TB aggregate RAM, 24× NVMe, GPU
sled. *Baseline* — 2 sleds, ~1 TB aggregate RAM, 16× NVMe (RAID10), GPU sled deferred.
Both run the full stack; the extra sleds and NVMe buy concurrency and dataset growth.

## Alternatives considered

- **PowerEdge R760 (2U rack server)** — the earlier single-box recommendation. Cheaper,
  but no multi-node scheduling, no chassis-level power/fabric redundancy, and a hard
  ceiling on RAM and drive bays. Superseded by the blade purchase.
- **PowerEdge R660** — 1U, denser/cheaper, fewer bays; fine as an add-on node.
- **PowerEdge R760xd2** — many drive bays; an option for the bulk tier if a JBOD/ME5 is
  not purchased.
- **Dell Precision 7960 Tower** — deskside workstation; adequate for a PoC, not for the
  official 24/7 platform.

## Why these choices (tied to the workload)

- **Multi-TB aggregate ECC RAM** — realistic concurrent use: ClickHouse ~48 GB,
  Elasticsearch (2 nodes) ~32 GB, RocksDB ~16 GB, Postgres/Kuzu/MinIO/API/etc. ~30 GB,
  **plus OS page-cache** for the multi-TB datasets (huge perf win). Spreading this over
  blades also lets K3s schedule heavy stores on separate nodes.
- **NVMe, not HDD** — ClickHouse/ES/RocksDB random I/O crawls on a ~150 MB/s spinning
  disk and flies on multi-GB/s NVMe. Put the **databases on NVMe**; MinIO's bulk objects
  (2.9 TB) live on the SAS tier.
- **RAID10 / ZFS mirror + backups** — a single un-mirrored disk = single point of data
  loss. Mirror the NVMe tier and keep a backup copy (the existing 22 TB HDD works as an
  extra backup target).
- **Blades, not one box** — rolling maintenance without full downtime, node-level
  failure isolation, and capacity growth by adding a sled instead of replacing a server.
- **iDRAC/OME-M + redundant PSU** — operational necessities for a racked, 24/7,
  lights-out platform.
- **GPU sled** — closes the one capability gap both proof-of-concept machines share
  (no GPU on the 31 GiB Linux box, Metal not exposed to Linux containers on the Mac).

## Platform software — K3s replaces OpenShift

| Layer | Choice |
|---|---|
| Kubernetes | **K3s** — one server node (or embedded-etcd HA across 3 sleds), agents on the rest |
| Manifests | NERC OpenShift export → `scripts/50-convert-manifests.py` (Routes → Ingress) |
| Ingress / TLS | ingress-nginx + cert-manager (Let's Encrypt) + Cloudflare Tunnel |
| Storage classes | `local-path` pinned to the NVMe tier for databases; Longhorn across sleds where replicated PVs are wanted; MinIO on the SAS tier |
| GPU | NVIDIA device plugin / GPU Operator on the GPU node |
| Monitoring | kube-prometheus-stack (Prometheus + Grafana) |

Rationale: the migration is already fully scripted, so OpenShift's operator and console
overhead earns nothing on owned hardware. K3s keeps the control plane small, makes
adding a blade a one-line agent join, and reuses the exact conversion path already
proven on the Linux PoC box. CRC/OpenShift remains only in the Mac proof-of-concept.

## AI tooling purchase (≈$50,000)

| Item | Purpose |
|---|---|
| Frontier-model API credits (Claude, plus a second vendor for redundancy) | agentic pipelines, literature/variant summarization, code generation |
| Coding/agent seats for the group | development and operation of HCloud itself |
| GPU software stack licenses (e.g. NVIDIA AI Enterprise) | supported drivers/containers on the GPU sled |
| MLOps / experiment tracking | training and evaluation runs, model registry |
| Vector / embedding infrastructure | retrieval over the genomics corpus (pgvector today) |
| Annotation & evaluation tooling | labeled sets and benchmark harnesses |
| Reserve for burst GPU cloud | overflow when a job exceeds the local sled |

Credits, seats, and licenses recur — track them against an annual run-rate so the
$50,000 is a planned budget, not a one-off.

## Server-room checklist

- [ ] 7U+ rack space for the MX7000 chassis, plus U for the storage array
- [ ] Dual power feeds → PDU → **UPS** (sized for chassis + storage)
- [ ] Adequate cooling / front-to-back airflow at blade density
- [ ] 25/100 GbE uplink to the network
- [ ] iDRAC + OpenManage Enterprise-Modular on the management VLAN
- [ ] Backup target for the NVMe data tier (SAS tier / NAS / offsite)

## One-line order

> **Dell PowerEdge MX7000** chassis · **3–4× MX750c blades** (2× Xeon Gold each,
> **512 GB–1 TB DDR5 ECC per sled**) · **GPU sled with 4× NVIDIA L40S** · BOSS-N1
> mirrored boot per sled · **storage rack: 16–24× 3.84 TB NVMe (RAID10)** · **ME5/JBOD
> 12–24× 8–20 TB SAS** for MinIO/backup · **MX9116n fabric, dual 25/100 GbE** ·
> **iDRAC9 Enterprise + OME-Modular** · redundant PSUs · 5-yr ProSupport — **≈$150,000**,
> plus **$50,000** AI tooling. Platform: **K3s**.

---

*Author: zhouhufeng <zhouhufeng@gmail.com> — sole author and maintainer.*
