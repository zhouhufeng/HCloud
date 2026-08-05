# Port HCloud to the production rack server & resume

This `HCloud/` folder is **self-contained**. To bring the whole migrated stack up on
a new machine (e.g. the Dell PowerEdge R760 — see `docs/HARDWARE.md`):

## What's in the folder

| Path | Contents | In git? |
|---|---|---|
| `scripts/`, `README.md`, `docs/*.md` | code, docs, resume tooling | ✅ yes |
| `cluster-data/` | the **migrated PVC data (~7.1 TB)**, stable volume names | ❌ git-ignored — travels on the drive |
| `docs/Secretes/` | kubeconfigs, secrets, `.../deploy/` manifests | ❌ git-ignored — travels on the drive |

> The data and secrets are **not** on GitHub (correctly). They live on the drive, so
> **port the physical drive** (fast) or copy the whole folder including `cluster-data/`.

## Resume in one command

```bash
# On the new machine, with this folder present (drive mounted or copied):
cd /path/to/HCloud
bash scripts/70-resume.sh
```

That will: install RKE2 → create static PVs pointing at `cluster-data/` → bind the
PVCs → apply all manifests → scale workloads to their original replicas. Then:

```bash
export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
/var/lib/rancher/rke2/bin/kubectl -n favor-4ee4be get pods -w
```

## Recommended on the rack server (production)

- **Storage tiering:** copy the DB volumes (`data-hg38-clickhouse-0`, `hg38-rocksdb`,
  `elasticsearch-data-*`, `data-postgres-0`, `kuzu-data-api-0`) onto **NVMe** for speed;
  leave `minio-pvc` (bulk objects) on the HDD. Point `cluster-data/` symlinks or the
  static-PV paths accordingly.
- **RAM:** with 256–512 GB the full stack runs at once (unlike the 31 GiB test box).

## Migration completeness (as of packaging)

Fully migrated (100%): **MinIO, RocksDB, Kuzu, Postgres, Higlass, api-cache**.
Needs finishing on the production box (has the RAM + NERC read access):
- **Elasticsearch** — most indices done; 2 big ones (`biokg`, `fav_variants`) need
  NERC mappings copied first, then reindex. See `docs/Secretes/migration/STATUS.md`.
- **ClickHouse** — ~87%; the last ~13% needs a brief NERC ClickHouse quiesce (cutover)
  for a consistent 1:1 (or a `remoteSecure` logical pull with more RAM).

NERC stays **read-only, untouched** throughout — it's the source of the copy.
