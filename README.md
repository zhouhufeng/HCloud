# HCloud — A Local Private Cloud to Replace NERC

HCloud is a self-hosted replacement for the terminating [NERC (New England Research Cloud)](https://nerc-project.github.io/nerc-docs/) platform. The group's NERC OpenShift project — pods, services, databases, object storage, and ~7–8 TiB of data — is migrated, kept running, and **served publicly** on hardware we own.

HCloud now has **two deployment platforms** in this one repo:

| Platform | Machine | Stack | Status |
|---|---|---|---|
| **Linux path** | `pc` — i7-12700, 31 GiB RAM, 22 TB HSA disk | **RKE2** bare-metal Kubernetes, ingress-nginx, Routes→Ingress | migration in progress (`docs/Secretes/migration/STATUS.md` on that box) |
| **Mac path (primary production)** | **Mac Studio** — Apple Silicon Ultra, **128 GiB RAM**, 20 TiB `/Volumes/HSZ` | **OpenShift Local (CRC)** — real OpenShift 4.22, native Routes/BuildConfigs, RHOAI-equivalent services | cluster up 2026-07-28; see `docs/mac-studio-runbook.md` |

> **Why two platforms?** The Linux box (31 GiB RAM) can't run the full NERC stack at once, so it pivoted to lean bare-metal RKE2 (no VM overhead) — see the platform note below. The Mac Studio has 128 GiB and can afford a **real OpenShift** cluster (96 GiB VM), which keeps everything NERC-native: `oc`, Routes, ImageStreams, BuildConfigs, the web console, and the RHOAI-style data-science stack. Both paths serve the public site via Cloudflare Tunnel + cert-manager.

> **Platform note for the Linux `pc` box (2026-07):** CRC there was retired for **RKE2** — CRC is a development-scale tool and the 31 GiB host needed the ~8–10 GB the VM cost. OpenShift `Route` objects are converted to `Ingress` (`scripts/50-convert-manifests.py`); everything else applies unchanged. On the Mac Studio, RAM is abundant, so CRC's convenience (true OpenShift API parity with NERC) wins — no manifest conversion beyond host names.

## HCloud vs. NERC — differences & benefits

| Dimension | **NERC** (source) | **HCloud Linux `pc`** | **HCloud Mac Studio** |
|---|---|---|---|
| Platform | Managed OpenShift 4 | RKE2 (CNCF Kubernetes), self-managed | OpenShift Local (CRC) 4.22 — real OpenShift |
| Topology | Multi-node datacenter (`wrk-0…wrk-35`) | Single node, bare-metal | Single node, 96 GiB VM |
| Compute | Distributed | i7-12700 (20 threads), **31 GiB** | Apple Silicon Ultra (20 cores), **128 GiB** |
| Storage | Ceph RBD — replicated | `local-path` on 22 TB HDD | CRC provisioner on 20 TiB `/Volumes/HSZ` (4 TiB VM disk) |
| Networking | Routes + managed DNS/TLS | ingress-nginx + Cloudflare Tunnel + cert-manager | native Routes + Cloudflare Tunnel + cert-manager |
| API / CLI | `oc`, Routes/SCC/ImageStreams | `kubectl`, Ingress (Routes converted) | `oc`, Routes/ImageStreams/BuildConfigs unchanged |
| Operations | Managed by NERC staff | Self-operated (this repo) | Self-operated (this repo) |
| Cost | Grant/allocation-based | Hardware you own | Hardware you own |
| Lifecycle | **Being decommissioned** | Persists as long as you run it | Persists as long as you run it |

**Benefits**

- **Continuity** — NERC is shutting down; HCloud keeps `favor-4ee4be` / genohub.org running.
- **Ownership & zero recurring cost** — no allocations to renew, no cloud invoice, no egress fees on ~8 TiB.
- **Full control** — root/admin over the whole stack; snapshot, experiment, reconfigure with no imposed quotas.
- **Data locality** — all data on local disk, LAN-speed and free to access.
- **Public hosting without a static IP** — Cloudflare Tunnel serves it publicly with free TLS, no port-forwarding.
- **Reproducible & portable** — fully scripted; redeploys onto bigger hardware with no rework.

**Honest trade-offs (vs NERC)**

- **No high availability** — one box is a single point of failure; expect downtime during power/network/hardware/update events. Fine for a research pilot, not a 99.9 %-uptime datacenter.
- **No storage redundancy** — single-disk PV backing on both machines; **a disk failure = data loss**; keep a backup copy.
- **You're the operator now** — upgrades, monitoring, and incident response move from NERC staff to you (mitigated by the repo's scripts).
- **Linux `pc` is RAM-bound (31 GiB)** — heavy analytics stores run one-at-a-time there until a 128 GB upgrade. The **Mac Studio does not have this wall** (96 GiB cluster).
- **No GPU on the Mac** — Apple Metal isn't exposed to Linux containers; GPU workloads stay a gap on both machines for now.

## Mac Studio — primary production target

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

## Recommended production hardware (department server room)

Sized to run the **entire** NERC-equivalent stack (ClickHouse, 2× Elasticsearch,
MinIO, RocksDB, Postgres/pgvector, Kuzu, API + workers) concurrently, with headroom
for growth and public serving. The two decisive factors are **RAM** (the constraint
that blocks the full stack on the 31 GiB dev box) and **fast NVMe storage** (the
databases do heavy random I/O — a spinning HDD is the bottleneck).

**Ideal production box — Dell Precision 7960 Tower (or PowerEdge T560 for a true server):**

| Component | Ideal production spec | Why |
|---|---|---|
| CPU | Xeon W9 / dual Xeon Scalable — **32–56 cores** | ClickHouse + concurrent search/API scale with cores |
| RAM | **512 GB DDR5 ECC** (256 GB minimum) | Runs all DBs at once **plus** OS page-cache for ~7 TB hot data; ECC is mandatory for 24/7 |
| Boot | 2 TB NVMe SSD | OS + RKE2 control plane |
| Database storage | **32 TB NVMe SSD, RAID10 / ZFS mirror** (e.g. 4–8× 8 TB) | ClickHouse/ES/RocksDB/Postgres need NVMe IOPS, not HDD; mirrored to survive a drive failure |
| Bulk / object + backup | 22 TB+ HDD or NAS | MinIO bulk objects + backup target for the NVMe tier |
| GPU (optional) | NVIDIA RTX 6000 Ada (48 GB) | AlphaGenome / ML inference; skip if CPU-only |
| Network | 10 GbE | Public serving + fast data movement |
| Resilience | RAID10/ZFS, redundant PSU, UPS, iDRAC/remote mgmt | Production posture — no single point of failure |

**Rack-mount option (for the department server room) — Dell PowerEdge R760, 2U:**

The same capability in a rack chassis with server-room essentials (redundant power,
hot-swap NVMe, remote management). Preferred over a tower when it lives in a rack.

| Component | Rack production spec | Why |
|---|---|---|
| Chassis | **PowerEdge R760, 2U**, ReadyRails sliding rail kit | Standard 2U depth; fits a 19″ rack |
| CPU | **2× Xeon Scalable (Gold), 32–64 cores total** | Dual-socket; ClickHouse/search/API scale with cores |
| RAM | **512 GB DDR5 ECC RDIMM** (256 GB min; scales to multi-TB) | Full stack + page-cache for ~7 TB hot data |
| Boot | **BOSS-N1: 2× 480 GB M.2 NVMe, RAID1** | Mirrored OS, separate from data |
| Database storage | **8× 3.84 TB U.2/E3.S NVMe, hot-swap, RAID10** (PERC H965i or ZFS) → ~15 TB usable | NVMe IOPS for the DBs; survives a drive failure |
| Bulk / object + backup | 4× 8 TB SAS/SATA (or external JBOD) for MinIO + backups | Cheap capacity tier |
| GPU (optional) | **R760xa** variant → up to 4× NVIDIA GPUs (RTX/L40S) | Only if AlphaGenome/ML needs GPU |
| Network | **dual 10/25 GbE** | Public serving + redundancy |
| Management | **iDRAC9 Enterprise** | Remote KVM/power — essential for a lights-out server room |
| Power | **redundant PSU (1+1), 1100–1400 W** | Dual PDU feeds; pair with rack UPS |

Denser/cheaper 1U alternative: **PowerEdge R660** (fewer drive bays). Storage-heavy
alternative: **R760xd2** (many bays) if MinIO/datasets grow large.

**Server-room checklist:** 2U rack space · dual power feeds + PDU + UPS · adequate
cooling/airflow · 10/25 GbE uplink · iDRAC on the management VLAN for remote ops.

**Baseline (works, tighter):** 24-core Xeon · 256 GB ECC · mirrored boot · 16 TB NVMe
(RAID10) · reuse a 22 TB HDD for MinIO/backups. This already runs the full stack
comfortably; scale RAM/NVMe up for more concurrent users and dataset growth.

**Deployment note:** put the database volumes (ClickHouse, Elasticsearch, RocksDB,
Postgres, Kuzu) on the **NVMe tier**; MinIO's bulk objects can live on the HDD/NAS.
Never run the platform off a single un-mirrored disk — keep a backup of the data tier.

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
```

## Migration from NERC (favor-4ee4be)

The source is a **live** OpenShift project (~7–8 TiB across 9 PVCs; MinIO ~3 TB, ClickHouse ~2.4 TB, RocksDB ~1.8 TB dominate). Approach:

1. **Export** every resource from NERC → `docs/Secretes/migration/favor-4ee4be/raw/` *(git-ignored — contains secrets)*. → `scripts/30-export-nerc.sh`
2. **Convert:**
   - Linux/RKE2: OpenShift → clean Kubernetes (Routes→Ingress, `local-path`). → `scripts/50-convert-manifests.py`
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

1. **Single node, no HA** on both machines — downtime during power/network/hardware events; acceptable for a research pilot.
2. **Single-disk storage** — no replication; keep backups. HDD on `pc` (~130–180 MB/s) caps bulk transfer; the Mac's Thunderbolt SSD volume is much faster.
3. **Linux `pc` is RAM-bound** until a 128 GB upgrade; the Mac Studio is not.
4. **No GPU workloads** on either box today (no NVIDIA hardware in the Mac; GTX 1080 passthrough on the home desktop was never promoted past optional).

## Repository layout

```
README.md            ← this document
scripts/             ← numbered setup + migration scripts (Linux + Mac chains)
docs/                ← runbooks: DEPLOYMENT-STATUS.md, mac-studio-runbook.md
docs/Secretes/       ← git-ignored: credentials, pull secret, migration exports/status
```
