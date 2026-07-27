# HCloud — A Local Private Cloud to Replace NERC

HCloud is a self-hosted replacement for the terminating [NERC (New England Research Cloud)](https://nerc-project.github.io/nerc-docs/) platform. It runs a **production Kubernetes cluster (RKE2) bare-metal on a Linux workstation**, so the group's NERC OpenShift project — pods, services, databases, object storage, and ~7 TiB of data — can be migrated, kept running, and **served publicly** on hardware we own.

> **Platform note (2026-07):** the project originally targeted OpenShift Local (CRC). We **pivoted to RKE2** because CRC is a Red-Hat *development/testing* tool — single-node, ephemeral, not supported for public production serving. RKE2 is a CNCF-certified, production-grade Kubernetes that runs bare-metal (no VM overhead), frees ~8–10 GB of RAM for workloads, and can serve the public website. OpenShift `Route` objects are converted to Kubernetes `Ingress`; everything else applies unchanged.

## This machine — `pc`

| | Detected |
|---|---|
| CPU | 12th Gen Intel i7-12700 — 20 threads, VT-x ✓ |
| RAM | 31 GiB |
| OS | Ubuntu 24.04 (noble), kernel 6.17 |
| Cluster storage | **`/media/hzhou/HSA` — 22 TB ext4** (`sdc2`), the cloud's PVC backing disk |
| Other disks | NVMe 476 GB (root, holds RKE2 control plane) · `HZR` 5.5 TB exfat · `HZU` 16.4 TB exfat (both ~90 % full) |
| Platform | **RKE2 v1.35.6** (bare-metal), ingress-nginx, `local-path` StorageClass on HSA |

**RAM is the binding constraint.** 31 GiB cannot run the full NERC stack (ClickHouse 2.3 TiB + 2× Elasticsearch + MinIO + Postgres + services) simultaneously — the web/API and lighter services run fine; the heavy analytics stores run one-at-a-time or trimmed. The i7-12700 boards take **128 GB DDR4/5** — that upgrade is the single highest-leverage improvement and removes the wall entirely.

## What HCloud is for

1. **A landing zone for the NERC project `favor-4ee4be`** (the genohub.org research platform). NERC is shutting down; HCloud gives every workload, config, and data volume a place to keep running.
2. **A public research cloud.** Once data is migrated, HCloud serves the site publicly under `genohub.org` via **cert-manager (Let's Encrypt) + Cloudflare Tunnel** — no static IP or router port-forwarding required.
3. **A portable, scripted platform.** Everything lives in this repo as numbered scripts + converted manifests, reproducible on new/larger hardware.

## Architecture

```
Internet ── Cloudflare Tunnel ── ingress-nginx ── Services ── Pods (favor-4ee4be)
                                                                  │
                          local-path PVCs  ──────────────────────┘
                          on /media/hzhou/HSA (22 TB ext4)
```

- **RKE2** bare-metal on the host (control plane on NVMe root).
- **Storage:** Rancher `local-path-provisioner`, default StorageClass, PV data on the 22 TB HSA disk.
- **Ingress:** ingress-nginx (ships with RKE2); OpenShift Routes → Ingress.
- **Public edge:** Cloudflare Tunnel + cert-manager (planned final phase).

## Migration from NERC (favor-4ee4be)

The source is a **live** OpenShift project (~7.0 TiB across 9 PVCs; MinIO 2.9 TB, ClickHouse 2.3 TB, RocksDB 1.7 TB dominate). Approach:

1. **Export** every resource from NERC → `docs/Secretes/migration/favor-4ee4be/raw/` *(git-ignored — contains secrets)*.
2. **Convert** OpenShift → clean Kubernetes: strip cluster-specific fields, drop OpenShift-generated secrets, `Route`→`Ingress`, `storageClassName`→`local-path`. → `scripts/50-convert-manifests.py`
3. **Apply** structure to RKE2 (workloads at `replicas: 0` until data lands).
4. **Copy data** while NERC stays up (live, point-in-time):
   - **MinIO** via in-cluster `rclone` over the S3 route (fast, parallel, resumable).
   - **Postgres** via `pg_dump`/`pg_restore`.
   - File volumes via a **mover pod + `tar` stream** (`scripts/60-migrate-volume.sh`); big immutable stores sharded into parallel streams (`scripts/61-migrate-bigvol.sh`).
   - **Elasticsearch** via snapshot API (live Lucene can't be `tar`'d consistently).
5. **Cutover delta-sync** when ready to switch off NERC → exact 1:1.

Live status is tracked in `docs/Secretes/migration/STATUS.md`.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/00-prereqs.sh` | Host virtualization/prereqs (legacy CRC path; kept for reference) |
| `scripts/40-install-rke2.sh` | **Install RKE2 bare-metal, retire CRC, put `local-path` storage on the 22 TB HSA disk** |
| `scripts/50-convert-manifests.py` | Convert exported OpenShift manifests → clean Kubernetes (Routes→Ingress, etc.) |
| `scripts/60-migrate-volume.sh` | Copy one live NERC volume → local PVC via a mover pod + tar stream |
| `scripts/61-migrate-bigvol.sh` | Sharded parallel transfer for large immutable stores (ClickHouse, RocksDB) |
| `scripts/30-export-nerc.sh` | Export a NERC namespace's manifests |
| `scripts/01-install-crc.sh`, `20-lan-access.sh` | Legacy CRC-era scripts (superseded by RKE2) |

## Quick start (fresh machine)

```bash
# 1. Install RKE2 + storage on the big disk
bash scripts/40-install-rke2.sh
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
export PATH=/var/lib/rancher/rke2/bin:$PATH
kubectl get nodes                       # node Ready

# 2. Export from NERC, convert, apply (see docs/Secretes/migration/RESUME.md)
python3 scripts/50-convert-manifests.py
kubectl apply -f docs/Secretes/migration/favor-4ee4be/clean/

# 3. Migrate data, then scale workloads up to original replicas
```

## Honest limits

1. **RAM (31 GiB)** can't run all heavy databases at once — upgrade to 128 GB for the full stack.
2. **Storage speed:** the 22 TB disk is a single spinning HDD (~130–180 MB/s sequential) — it, not the network, caps bulk transfer.
3. **Single node:** no HA. A production public site on one box means downtime during power/network/hardware events — acceptable for a research pilot, not a datacenter.
4. **CRC files** (`docs/DEPLOYMENT-STATUS.md`, `01-install-crc.sh`) reflect the earlier OpenShift-Local approach, kept for history.

## Repository layout

```
README.md            ← this document
scripts/             ← numbered setup + migration scripts
docs/                ← runbooks (DEPLOYMENT-STATUS.md)
docs/Secretes/       ← git-ignored: credentials, pull secret, migration exports/status
```
