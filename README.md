# HCloud — A Local Private Cloud to Replace NERC

HCloud is a self-hosted replacement for the terminating [NERC (New England Research Cloud)](https://nerc-project.github.io/nerc-docs/) platform. The group's NERC OpenShift project — pods, services, databases, object storage, and ~7–8 TiB of data — is migrated, kept running, and **served publicly** on hardware we own.

**Current hardware platform.** Today HCloud runs on two proof-of-concept boxes —
the Linux `pc` and the Mac Studio — both **personal hardware**. They prove that HCloud
can replace NERC's OpenShift on infrastructure we own, but neither is production-grade
(the 31 GiB Linux box is RAM-bound; Apple Silicon has no GPU or Linux-container
parity). The **official version of HCloud runs on purchased datacenter hardware**,
budgeted as:

| Line item | Budget | What it buys |
|---|---|---|
| **Dell server blades + storage rack** | **$150,000** | Modular blade chassis with multiple compute sleds (multi-TB aggregate ECC RAM, optional GPU sled) plus a dedicated **storage rack** (NVMe database tier + bulk/backup capacity), redundant power and out-of-band management — see [official platform spec](#official-platform-150000-dell-blades--storage-rack) and [`docs/HARDWARE.md`](docs/HARDWARE.md) |
| **AI tooling & software** | **$50,000** | Model API credits, coding/agent seats, GPU-stack and MLOps licenses, vector/embedding infrastructure, annotation and evaluation tooling — see [AI tooling purchase](#ai-tooling-purchase-50000) |
| **Total** | **$200,000** | Full-service HCloud: the whole NERC stack concurrently + GPU/AI workloads, served publicly 24/7 |

**Platform decision: K3s replaces OpenShift in production.** The official deployment
runs **K3s** (lightweight CNCF Kubernetes) on the blades — not OpenShift. OpenShift's
operator/console overhead buys nothing here now that the migration is scripted, and
K3s gives a small control plane, trivial multi-node joins across blades, and the same
manifest path already proven on the Linux box: OpenShift `Route` objects are converted
to `Ingress` by `scripts/50-convert-manifests.py`, everything else applies unchanged.
CRC/OpenShift stays only in the Mac proof-of-concept.

Versus the proof-of-concept boxes this purchase changes three things: the **RAM wall
disappears** (the entire NERC stack runs concurrently instead of one heavy store at a
time), storage moves from a single spinning disk to a **redundant NVMe + bulk rack**,
and **GPU workloads become possible** for the first time — the one capability gap both
test machines share.

| Deployment | Role | Machine | Stack | Status |
|---|---|---|---|---|
| **Linux path** | proof-of-concept | `pc` — i7-12700, 31 GiB RAM, 22 TB disk | RKE2 bare-metal Kubernetes, Routes→Ingress | ✅ tested; full NERC→local data migration validated |
| **Mac path** | proof-of-concept | Mac Studio — Apple Silicon, 128 GiB RAM, 20 TiB `/Volumes/HSZ` | OpenShift Local (CRC) 4.22, native Routes/BuildConfigs | ✅ tested; cluster up 2026-07-28 (`docs/mac-studio-runbook.md`) |
| **Official version** | **production deployment** | **$150,000 Dell server blades + storage rack** | **K3s** (multi-node) + Ingress, public serving, GPU/AI, 24/7 | ⬜ on hardware purchase |

> **Why two proof-of-concept tests?** They de-risk the approach on hardware we already
> had. The Linux box proved a lean bare-metal **RKE2** path and the complete NERC→local
> **data migration** (~7–8 TiB). The Mac Studio (128 GiB) proved a **real OpenShift**
> (CRC) path with full NERC API parity (`oc`, Routes, BuildConfigs, RHOAI-style stack).
> Both confirm HCloud is viable — but neither test box is production-grade (the 31 GiB
> Linux box is RAM-bound; Apple Silicon lacks GPU/Linux-container parity). The **real
> deployment happens on the $150,000 Dell blades + storage rack under K3s**, which has
> the RAM, NVMe, redundancy, and multi-node headroom to run the entire stack for the
> department 24/7.

> **Platform note for the Linux `pc` box (2026-07):** CRC there was retired for **RKE2** — CRC is a development-scale tool and the 31 GiB host needed the ~8–10 GB the VM cost. OpenShift `Route` objects are converted to `Ingress` (`scripts/50-convert-manifests.py`); everything else applies unchanged. On the Mac Studio, RAM is abundant, so CRC's convenience (true OpenShift API parity with NERC) wins — no manifest conversion beyond host names.

## HCloud vs. NERC — differences & benefits

| Dimension | **NERC** (source) | **HCloud official** (Dell blades + storage rack) | **HCloud Linux `pc`** (PoC) | **HCloud Mac Studio** (PoC) |
|---|---|---|---|---|
| Platform | Managed OpenShift 4 | **K3s** (CNCF Kubernetes), self-managed | RKE2 (CNCF Kubernetes), self-managed | OpenShift Local (CRC) 4.22 — real OpenShift |
| Topology | Multi-node datacenter (`wrk-0…wrk-35`) | **Multi-node blades** in one chassis + storage rack | Single node, bare-metal | Single node, 96 GiB VM |
| Compute | Distributed | Blade sleds — **multi-TB aggregate ECC RAM**, optional GPU sled | i7-12700 (20 threads), **31 GiB** | Apple Silicon Ultra (20 cores), **128 GiB** |
| Storage | Ceph RBD — replicated | **Redundant NVMe tier (RAID10) + bulk/backup rack** | `local-path` on 22 TB HDD | CRC provisioner on 20 TiB `/Volumes/HSZ` (4 TiB VM disk) |
| Networking | Routes + managed DNS/TLS | ingress-nginx + Cloudflare Tunnel + cert-manager | ingress-nginx + Cloudflare Tunnel + cert-manager | native Routes + Cloudflare Tunnel + cert-manager |
| API / CLI | `oc`, Routes/SCC/ImageStreams | `kubectl`, Ingress (Routes converted) | `kubectl`, Ingress (Routes converted) | `oc`, Routes/ImageStreams/BuildConfigs unchanged |
| GPU / AI | Available on allocation | **GPU sled + $50k AI tooling budget** | none | none (Metal not exposed) |
| Operations | Managed by NERC staff | Self-operated (this repo) | Self-operated (this repo) | Self-operated (this repo) |
| Cost | Grant/allocation-based | **$150k hardware + $50k AI tooling, owned** | Hardware you own | Hardware you own |
| Lifecycle | **Being decommissioned** | Persists as long as you run it | Persists as long as you run it | Persists as long as you run it |

**Benefits**

- **Continuity** — NERC is shutting down; HCloud keeps `favor-4ee4be` / genohub.org running.
- **Ownership & zero recurring cost** — no allocations to renew, no cloud invoice, no egress fees on ~8 TiB.
- **Full control** — root/admin over the whole stack; snapshot, experiment, reconfigure with no imposed quotas.
- **Data locality** — all data on local disk, LAN-speed and free to access.
- **Public hosting without a static IP** — Cloudflare Tunnel serves it publicly with free TLS, no port-forwarding.
- **Reproducible & portable** — fully scripted; redeploys onto bigger hardware with no rework.

**Honest trade-offs (vs NERC)**

_These are the trade-offs of the **proof-of-concept** boxes; the $150k blade + storage-rack
purchase is what retires most of them._

- **No high availability on the PoC boxes** — one box is a single point of failure; expect downtime during power/network/hardware/update events. Fine for a research pilot, not a 99.9 %-uptime datacenter. The blade chassis restores multi-node scheduling and redundant power.
- **No storage redundancy on the PoC boxes** — single-disk PV backing on both machines; **a disk failure = data loss**; keep a backup copy. The storage rack adds RAID10 NVMe plus a bulk/backup tier.
- **You're the operator now** — upgrades, monitoring, and incident response move from NERC staff to you (mitigated by the repo's scripts). This does not change with the purchase.
- **Linux `pc` is RAM-bound (31 GiB)** — heavy analytics stores run one-at-a-time there until a 128 GB upgrade. The **Mac Studio does not have this wall** (96 GiB cluster), and the blades remove it outright.
- **No GPU on either test box** — Apple Metal isn't exposed to Linux containers and the Linux box has no data-center GPU; GPU workloads remain a gap **until the GPU sled arrives with the purchase**.

## Mac Studio — proof-of-concept (real-OpenShift path)

_A concept test on personal hardware, not the production target — the formal
deployment is the rack server. This validated a full OpenShift (CRC) path with
NERC API parity._


Full runbook: **`docs/mac-studio-runbook.md`**. NERC-service parity mapping:

| NERC service | HCloud equivalent (Mac Studio) | Script |
|---|---|---|
| OpenShift container platform | CRC — 16 vCPU / 96 GiB / 4 TiB on `/Volumes/HSZ` | 61 |
| Web console, `oc`, Routes, builds, image registry | Included in CRC | 61 |
| Public app URLs (`*.apps.shift.nerc.mghpcc.org`) | Cloudflare Tunnel → `*.<your-domain>` | 62 |
| TLS certificates | cert-manager + Let's Encrypt (Cloudflare DNS-01) | 63 |
| Block storage (`ocs-external-storagecluster-ceph-rbd`) | StorageClass **alias with the same name** → CRC provisioner | 64 |
| Object storage (MinIO S3) | MinIO operator | 64 |
| Projects, quotas, RBAC, multi-user (ColdFront feel) | htpasswd users + per-project ResourceQuota/LimitRange | 65 |
| RHOAI (JupyterLab, workbenches, KServe model serving) | OpenDataHub operator (RHOAI upstream) | 66 |
| Serverless Computing (Knative) | OpenShift Serverless operator | 66 |
| CI/CD Pipeline | OpenShift Pipelines (Tekton) operator | 66 |
| Cluster monitoring (Prometheus/Grafana) | CRC cluster-monitoring enabled at install | 61 |
| Your NERC pods & services | Export → convert → apply → data rsync → scale up | 30, 67–69 |
| Keycloak/CILogon SSO | follow-up after public URL exists (htpasswd first) | — |
| GPU workloads | **not available on Apple Silicon** (honest gap) | — |

## The Linux machine — `pc`

| | Detected |
|---|---|
| CPU | 12th Gen Intel i7-12700 — 20 threads, VT-x ✓ |
| RAM | 31 GiB |
| OS | Ubuntu 24.04 (noble), kernel 6.17 |
| Cluster storage | **`/media/hzhou/HSA` — 22 TB ext4** (`sdc2`), the cloud's PVC backing disk |
| Other disks | NVMe 476 GB (root, holds RKE2 control plane) · `HZR` 5.5 TB exfat · `HZU` 16.4 TB exfat (both ~90 % full) |
| Platform | **RKE2 v1.35.6** (bare-metal), ingress-nginx, `local-path` StorageClass on HSA |

**RAM is the binding constraint on `pc`.** 31 GiB cannot run the full NERC stack (ClickHouse 2.3 TiB + 2× Elasticsearch + MinIO + Postgres + services) simultaneously — the web/API and lighter services run fine; the heavy analytics stores run one-at-a-time or trimmed. The i7-12700 boards take **128 GB DDR4/5** — that upgrade removes the wall entirely.

## Official platform — $150,000 Dell blades + storage rack

The official HCloud version, in the department server room: a **Dell modular blade
chassis** with several compute sleds and a **dedicated storage rack**, running **K3s**.
Sized to run the **entire** NERC-equivalent stack (ClickHouse, 2× Elasticsearch, MinIO,
RocksDB, Postgres/pgvector, Kuzu, API + workers) concurrently, serve the public site,
and grow. Full purchasing summary in [`docs/HARDWARE.md`](docs/HARDWARE.md).

The two decisive factors are **RAM** (the constraint that blocks the full stack on the
31 GiB PoC box) and **fast NVMe storage** (the databases do heavy random I/O — a
spinning HDD is the bottleneck).

| Component | Official spec (≈$150,000 as configured) | Why |
|---|---|---|
| Chassis | **Dell PowerEdge MX7000** modular enclosure (7U) + rails | Blade backplane, shared power/fabric, one management plane |
| Compute blades | **3–4× MX750c sleds**, each 2× Xeon Scalable (Gold), 32–64 cores | K3s server + agent nodes; real multi-node scheduling |
| RAM | **512 GB–1 TB DDR5 ECC per sled → 2–3 TB aggregate** | Full stack + OS page-cache for the ~7 TB hot dataset |
| GPU | **1× GPU sled / PowerEdge R760xa** → up to 4× NVIDIA (L40S / RTX 6000 Ada) | AlphaGenome/ML and the AI tooling workloads |
| Boot | **BOSS-N1 per sled: 2× 480 GB M.2 NVMe, RAID1** | Mirrored OS, separate from data |
| Database storage | **Storage rack: 16–24× 3.84 TB U.2/E3.S NVMe, hot-swap, RAID10** (PERC H965i or ZFS) → ~30–45 TB usable | NVMe IOPS for the DBs; survives drive failure |
| Bulk / object + backup | **Dell ME5 / JBOD: 12–24× 8–20 TB SAS** for MinIO + backups | Cheap capacity tier, ~150–300 TB raw |
| Fabric / network | **MX9116n fabric switching engine, dual 25/100 GbE uplinks** | East-west blade traffic + public serving, redundant |
| Management | **iDRAC9 Enterprise + OpenManage Enterprise-Modular** | Remote KVM/power — essential lights-out |
| Power | **Chassis redundant PSUs (N+N), dual PDU feeds** | Pair with rack UPS |
| Support | **5-year ProSupport** on chassis, sleds, and storage | Production support window |

**Why K3s instead of OpenShift here:** the migration path is already scripted, so
OpenShift's operator/console overhead earns nothing on owned hardware. K3s gives a
small, fast control plane, one-line agent joins as blades are added, and reuses the
proven `Route`→`Ingress` conversion (`scripts/50-convert-manifests.py`) plus
ingress-nginx + cert-manager + Cloudflare Tunnel. Storage: `local-path` on the NVMe
tier for databases, or Longhorn across sleds when replicated PVs are wanted.

**Server-room checklist:** 7U+ rack space for the chassis and storage · dual power
feeds + PDU + **UPS** · front-to-back cooling · 25/100 GbE uplink · iDRAC/OME-M on the
management VLAN · backup target for the NVMe data tier.

**Deployment note:** put the database volumes (ClickHouse, Elasticsearch, RocksDB,
Postgres, Kuzu) on the **NVMe tier**; MinIO's bulk objects live on the SAS/JBOD tier.
Never run the platform off a single un-mirrored disk — keep a backup of the data tier.

## AI tooling purchase — $50,000

Software and services that sit on top of the platform (the hardware budget buys none
of this):

| Item | Purpose |
|---|---|
| **Frontier-model API credits** (Claude, plus a second vendor for redundancy) | Agentic pipelines, literature/variant summarization, code generation on the platform |
| **Coding/agent seats** (Claude Code and equivalents) for the group | Day-to-day development and operations of HCloud itself |
| **GPU software stack licenses** (e.g. NVIDIA AI Enterprise) | Supported drivers/containers for the GPU sled |
| **MLOps / experiment tracking** | Training and evaluation runs, model registry |
| **Vector / embedding infrastructure** | Retrieval over the genomics corpus (pgvector today, room to grow) |
| **Annotation & evaluation tooling** | Labeled sets and benchmark harnesses for model quality |
| **Reserve for burst GPU cloud** | Overflow when a training job exceeds the local sled |

Recurring costs (credits, seats, licenses) are tracked annually so the $50,000 is spent
against a known run-rate rather than one-off.

## What HCloud is for

1. **A landing zone for the NERC project `favor-4ee4be`** (the genohub.org research platform). NERC is shutting down; HCloud gives every workload, config, and data volume a place to keep running.
2. **A public research cloud.** Once data is migrated, HCloud serves the site publicly under `genohub.org` via **cert-manager (Let's Encrypt) + Cloudflare Tunnel** — no static IP or router port-forwarding required.
3. **A portable, scripted platform.** Everything lives in this repo as numbered scripts + converted manifests, reproducible on new/larger hardware.

## Architecture

```
Linux pc:   Internet ── Cloudflare Tunnel ── ingress-nginx ── Services ── Pods
                                                                  │
                              local-path PVCs on /media/hzhou/HSA (22 TB)

Mac Studio: Internet ── Cloudflare Tunnel ── OpenShift Router ── Routes ── Pods
                                                                  │
                              CRC PVCs in 4 TiB VM disk on /Volumes/HSZ (20 TiB)

Official:   Internet ── Cloudflare Tunnel ── ingress-nginx ── Services ── Pods
            (K3s on Dell blades)                                  │
                        ┌─────────────────────────────────────────┴──────────┐
                        │ NVMe RAID10 tier (databases)   SAS/JBOD (MinIO,    │
                        │ on the storage rack            backups)            │
                        └────────────────────────────────────────────────────┘
```

## Migration from NERC (favor-4ee4be)

The source is a **live** OpenShift project (~7–8 TiB across 9 PVCs; MinIO ~3 TB, ClickHouse ~2.4 TB, RocksDB ~1.8 TB dominate). Approach:

1. **Export** every resource from NERC → `docs/Secretes/migration/favor-4ee4be/raw/` *(git-ignored — contains secrets)*. → `scripts/30-export-nerc.sh`
2. **Convert:**
   - Official K3s blades (and Linux/RKE2 PoC): OpenShift → clean Kubernetes (Routes→Ingress, `local-path`). → `scripts/50-convert-manifests.py` — the same converted manifests apply on K3s unchanged
   - Mac/CRC: OpenShift → OpenShift (only strip cluster fields + rewrite Route hosts). → `scripts/67-migrate-to-crc.py`
3. **Apply** structure (workloads at `replicas: 0` until data lands).
4. **Copy data** while NERC stays up: mover-pod tar streams (`60/61-migrate-*.sh` on Linux; `68-rsync-nerc-data.sh` on Mac); MinIO via rclone; Postgres via `pg_dump`; Elasticsearch via snapshot API.
5. **Cutover delta-sync**, scale up (`scripts/69-scale-up.sh`), rotate NERC tokens.

## Scripts

| Script | Path | Purpose |
|---|---|---|
| `00-prereqs.sh`, `01-install-crc.sh`, `20-lan-access.sh` | Linux | Legacy CRC-era scripts (superseded on `pc` by RKE2) |
| `30-export-nerc.sh` | both | Export a NERC namespace's manifests (→ git-ignored path) |
| `40-install-rke2.sh` | Linux | Install RKE2 bare-metal, storage on the 22 TB HSA disk |
| `50-convert-manifests.py` | Linux | Convert OpenShift manifests → clean Kubernetes (Routes→Ingress) |
| `60-migrate-volume.sh` | Linux | Copy one live NERC volume → local PVC via mover pod + tar stream |
| `61-migrate-bigvol.sh` | Linux | Sharded parallel transfer for large immutable stores |
| `60-mac-prereqs.sh` | **Mac** | Homebrew + crc/oc/helm/cloudflared/htpasswd/jq |
| `61-install-crc-mac.sh` | **Mac** | CRC mac-studio profile (16 vCPU / 96 GiB / 4 TiB), `~/.crc` → `/Volumes/HSZ`, daemon workaround |
| `62-cloudflared-tunnel.sh` | **Mac** | Cloudflare Tunnel (launchd) → OpenShift router, wildcard DNS |
| `63-cert-manager.sh` | **Mac** | cert-manager + Let's Encrypt wildcard via Cloudflare DNS-01 |
| `64-storage-parity.sh` | **Mac** | NERC StorageClass-name alias + MinIO operator |
| `65-users-quotas.sh` | **Mac** | htpasswd IdP, per-user projects, NERC-style quotas |
| `66-nerc-services.sh` | **Mac** | OpenDataHub + OpenShift Serverless + Pipelines operators |
| `67-migrate-to-crc.py` | **Mac** | Convert raw NERC export → CRC-ready manifests (Routes kept) |
| `68-rsync-nerc-data.sh` | **Mac** | Per-PVC data copy NERC→CRC via helper pods (resumable) |
| `69-scale-up.sh` | **Mac** | Restore original replica counts after data migration |

## Quick start

```bash
# ----- Linux pc (RKE2) -----
bash scripts/40-install-rke2.sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml PATH=/var/lib/rancher/rke2/bin:$PATH
python3 scripts/50-convert-manifests.py
kubectl apply -f docs/Secretes/migration/favor-4ee4be/clean/

# ----- Mac Studio (CRC / OpenShift) -----
bash scripts/60-mac-prereqs.sh          # tools (or install the official CRC pkg)
bash scripts/61-install-crc-mac.sh      # cluster up on /Volumes/HSZ
bash scripts/64-storage-parity.sh       # NERC storage-class alias + MinIO
HCLOUD_USERS='hzhou' bash scripts/65-users-quotas.sh
bash scripts/66-nerc-services.sh        # ODH / Serverless / Pipelines
python3 scripts/67-migrate-to-crc.py --ns favor-4ee4be
oc apply -f docs/Secretes/migration/favor-4ee4be/crc/
# then: 68 (data), 69 (scale up); 62-63 for public serving
```

## Honest limits

Limits of the **proof-of-concept** boxes running today:

1. **Single node, no HA** on both machines — downtime during power/network/hardware events; acceptable for a research pilot. Resolved by the multi-blade K3s cluster.
2. **Single-disk storage** — no replication; keep backups. HDD on `pc` (~130–180 MB/s) caps bulk transfer; the Mac's Thunderbolt SSD volume is much faster. Resolved by the NVMe RAID10 storage rack.
3. **Linux `pc` is RAM-bound** until a 128 GB upgrade; the Mac Studio is not.
4. **No GPU workloads** on either box today (no NVIDIA hardware in the Mac; GTX 1080 passthrough on the home desktop was never promoted past optional). Resolved by the GPU sled in the purchase.

Limits that remain **after** the purchase: you are still the operator (upgrades,
monitoring, incident response), the cluster lives in one server room (no second site
without an offsite backup target), and the $50,000 AI tooling budget covers recurring
credits/seats that must be renewed.

## Repository layout

```
README.md            ← this document
scripts/             ← numbered setup + migration scripts (Linux + Mac chains)
docs/                ← runbooks: DEPLOYMENT-STATUS.md, HARDWARE.md, mac-studio-runbook.md
docs/Secretes/       ← git-ignored: credentials, pull secret, migration exports/status
```

## Author

**zhouhufeng** — <zhouhufeng@gmail.com> — sole author and maintainer of HCloud.
