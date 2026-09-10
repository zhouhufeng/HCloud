# Platform: Linux bare metal — the `pc` proof-of-concept

Any Linux host is an HCloud platform after `platform/linux/10-host-prep.sh`. This page
records the one that has run the most: the office desktop `pc`, which carried the whole
NERC migration.

| | Detected (2026-07-04) |
|---|---|
| CPU | 12th Gen Intel i7-12700 — 20 threads, VT-x |
| RAM | 31 GiB |
| OS | Ubuntu 24.04 (noble) |
| Cluster storage | `/media/hzhou/HSA` — 22 TB ext4, the PV backing disk (`HCLOUD_STORAGE_DIR=/media/hzhou/HSA/rke2-storage`) |
| Other disks | NVMe 476 GB (root, control plane) · `HZR` 5.5 TB · `HZU` 16.4 TB (exfat, ~90 % full) |
| Kubernetes | **RKE2 v1.35.6**, bundled ingress-nginx, `local-path` on HSA |

## What it proved

- The complete NERC → Kubernetes conversion path (Routes → Ingress, `local-path` PVCs).
- The live data copy of ~7.1 TiB via mover pods and sharded tar streams over a
  ~130–180 MB/s HDD — MinIO, RocksDB, Kuzu, Postgres, HiGlass, api-cache complete;
  ClickHouse ~87 %, Elasticsearch minus two big indices (see `docs/MIGRATION.md`).
- That CRC/OpenShift is the wrong tool on a 31 GiB box (the VM alone cost 8–10 GB); it was
  retired for RKE2 in 2026-07, which led to the K3s middleware.

## Limits

**RAM is the binding constraint.** 31 GiB cannot run ClickHouse (2.4 TB) + 2× Elasticsearch
+ MinIO + Postgres + services concurrently; heavy stores run one at a time. The board
takes 128 GB, which removes the wall. Single node, single disk: no HA, no replication —
keep the HSA data as the staging copy and back it up. No GPU.

## Running the middleware here

`pc` already runs RKE2 with the bundled ingress and the migrated data; **do not re-run the
K3s installer on it**. For a fresh Linux box the path is the README quick start with
`HCLOUD_K8S_DISTRO=k3s`. To rebuild `pc` from the drive: `apps/nerc-migration/60-resume.sh`
with `HCLOUD_K8S_DISTRO=rke2` in `hcloud.env` (fresh RKE2 installs now disable the bundled
ingress so the middleware's ingress-nginx is the one ingress, like every other platform).

Ubuntu 24.04 gotchas from the CRC era (virtiofsd, libvirt group) are in
`docs/DEPLOYMENT-STATUS.md` and no longer apply to the K3s/RKE2 path.
