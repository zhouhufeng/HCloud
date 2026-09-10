# NERC → HCloud: the application-layer runbook

The first (and defining) HCloud application is the NERC OpenShift project
**`favor-4ee4be`** — the genohub.org research platform. NERC (New England Research Cloud)
is being decommissioned; HCloud keeps every workload, config and data volume running and
served publicly. Scripts: [`apps/nerc-migration/`](../apps/README.md). This page is the
procedure, the workload inventory, the status, and the honest comparison with NERC.

## Procedure

The source is a **live** OpenShift project (~7–8 TiB across 9 PVCs). NERC stays
read-only and untouched throughout; it is the source of the copy.

| Step | Script | Notes |
|---|---|---|
| 1. Export | `10-export-nerc.sh favor-4ee4be` | `oc login` to NERC first. Everything → `docs/Secretes/migration/favor-4ee4be/raw/` (git-ignored, contains secrets) |
| 2. Convert | `20-convert-manifests.py --ns favor-4ee4be --domain $HCLOUD_DOMAIN` | OpenShift → Kubernetes: Routes → Ingress on `nginx` with hosts `<name>.$HCLOUD_DOMAIN`; PVCs → `local-path`; workloads at `replicas: 0`; originals → `_replicas.json`. Output `…/clean/` |
| 3. Apply structure | `30-apply.sh favor-4ee4be` | PVCs, config, services, Ingresses, workloads (scaled to 0) |
| 4. Copy data | `40-migrate-volume.sh` per volume; `41-migrate-bigvol.sh` for ClickHouse/RocksDB | Mover pod on HCloud + `oc exec … tar` from the live NERC pod, retried, sharded for the big stores. MinIO can also go via `rclone`, Postgres via `pg_dump`, Elasticsearch via the snapshot API |
| 5. Cutover | scale NERC to 0 → final delta pass of step 4 → `50-scale-up.sh favor-4ee4be` | Then rotate the NERC token and, when confident, release the allocation |

Custom domain: `api-v2.genohub.org` should stay as-is for external clients. Route
`genohub.org` through the same Cloudflare Tunnel (`cloudflared tunnel route dns hcloud
api-v2.genohub.org`) and keep that one Ingress host un-rewritten.

Mac/CRC variant (OpenShift → OpenShift, kept for the proof-of-concept):
`platform/mac/crc/17-migrate-to-crc.py` + `18-rsync-nerc-data.sh`, then
`HCLOUD_MANIFEST_VARIANT=crc apps/nerc-migration/50-scale-up.sh`.

## Resume / port to a new host

The folder is self-contained. Besides git it carries two git-ignored trees on the drive:

| Path | Contents |
|---|---|
| `cluster-data/<pvc-name>/` | the migrated PVC data (~7.1 TiB), stable volume names |
| `docs/Secretes/` | kubeconfigs, secrets, `migration/favor-4ee4be/{raw,clean,deploy}/` |

On any host that the platform layer has prepared (drive mounted or folder copied):

```bash
bash apps/nerc-migration/60-resume.sh      # middleware if needed → static PVs on cluster-data/ → bind → apply → scale up
kubectl -n favor-4ee4be get pods -w
```

On the Dell blades, copy the database volumes (`data-hg38-clickhouse-0`, `hg38-rocksdb`,
`elasticsearch-data-*`, `data-postgres-0`, `kuzu-data-api-0`) to the NVMe tier and leave
`minio-pvc` on bulk; point `HCLOUD_DATA_DIR` or per-volume symlinks accordingly. **Do not
copy 7 TB twice**: bring the new platform up empty, validate it, then move the data once.

## The workload

Exported 2026-07-09:

```
StatefulSets  : api, elasticsearch-autocomplete-es-default (×2), hg38-clickhouse,
                higlass, nats, postgres, rocksdb-index-service
Deployments   : batch-worker (2), jaeger, minio-deployment, nats-box (0/0)
Routes        : 11  (incl. custom domain api-v2.genohub.org)   → Ingress
Services      : 24  (many headless)
Secrets/CMs   : 44 secrets, 25 configmaps
Roles / RBs   : 4 roles, 14 rolebindings
Image build   : 1 BuildConfig, 2 ImageStreams (OpenShift-only; images are pre-built and pulled)
```

| PVC | Size | Placement on the blades |
|---|---|---|
| `minio-pvc` | 3 Ti (2.9 TB used) | bulk / SAS tier |
| `data-hg38-clickhouse-0` | 2600 Gi (2.4 TB used) | NVMe |
| `hg38-rocksdb` | 2 Ti (1.6 TiB used) | NVMe |
| `elasticsearch-data-…-0/1` | 115 Gi ×2 | NVMe, different nodes |
| `higlass-data` | 100 Gi | any |
| `data-postgres-0` | 50 Gi | NVMe or replicated |
| `kuzu-data-api-0` | 30 Gi | NVMe |
| `api-cache-api-0` | 500 Mi | any |

## Migration status

Fully migrated onto the Linux `pc` (RKE2) staging copy: **MinIO, RocksDB, Kuzu, Postgres,
HiGlass, api-cache**. Remaining, to finish on a host with enough RAM and NERC read access:

- **Elasticsearch** — most indices done; `biokg` and `fav_variants` need their NERC
  mappings copied first, then a reindex. Details: `docs/Secretes/migration/STATUS.md`.
- **ClickHouse** — ~87 %; the last ~13 % needs a brief NERC ClickHouse quiesce (cutover)
  for a consistent 1:1, or a `remoteSecure` logical pull with more RAM.

## HCloud vs NERC

| Dimension | NERC (source) | HCloud on the Dell blades | HCloud proofs-of-concept (pc / Mac) |
|---|---|---|---|
| Platform | Managed OpenShift 4 | K3s, self-managed | RKE2 / OpenShift Local |
| Topology | Multi-node datacenter | Multi-node blades + storage rack | Single node |
| Storage | Ceph RBD, replicated | NVMe RAID10 tier + bulk/backup rack | single disk |
| Networking | Routes + managed DNS/TLS | ingress-nginx + cert-manager + Cloudflare Tunnel | same |
| API | `oc`, Routes/SCC/ImageStreams | `kubectl`, Ingress (Routes converted once) | same / native `oc` on CRC |
| GPU / AI | on allocation | GPU sled + $50k AI tooling | none |
| Operations | NERC staff | us, via this repo | us |
| Cost | grant allocation | owned; no recurring cloud bill or egress on ~8 TiB | owned |
| Lifecycle | being decommissioned | as long as we run it | as long as we run it |

**Benefits:** continuity for genohub.org; ownership and zero recurring cost; root over the
whole stack; LAN-speed data; public hosting without a static IP; fully scripted and
portable across platforms (this repository's whole point).

**Trade-offs, honestly:** we are the operators now — upgrades, monitoring, incident
response. The proof-of-concept boxes are single node, single disk (a disk failure is data
loss; keep the backup copy), RAM-bound on `pc`, and GPU-less. The blade purchase retires
the hardware limits; it does not retire the operator role, and a single server room means
an offsite backup target is still needed.
