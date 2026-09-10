# `apps/` — the application layer

Workloads that run **on** HCloud. They see only the contract the middleware guarantees
(IngressClass `nginx`, the three StorageClass names, a public wildcard domain) and never
touch the hosting platform.

| Directory | What |
|---|---|
| `nerc-migration/` | Bringing the NERC OpenShift project `favor-4ee4be` (genohub.org, ~7–8 TiB) onto HCloud: export → convert → apply → copy data → scale up, plus a one-command resume from the packaged data. Runbook: [`docs/MIGRATION.md`](../docs/MIGRATION.md) |

## `nerc-migration/` scripts

| # | Script | Purpose |
|---|---|---|
| 10 | `10-export-nerc.sh <ns>` | Export every resource of a NERC namespace → `docs/Secretes/migration/<ns>/raw/` (git-ignored, contains secrets) |
| 20 | `20-convert-manifests.py --ns <ns> --domain <HCLOUD_DOMAIN>` | OpenShift → plain Kubernetes: Routes→Ingress with hosts rewritten to `<name>.<domain>`, `local-path` PVCs, workloads at `replicas: 0`, originals in `_replicas.json` → `…/clean/` |
| 30 | `30-apply.sh <ns>` | Apply `clean/` in order |
| 40 | `40-migrate-volume.sh <name> <nerc_pod> <path> <pvc>` | Copy one live NERC volume into its HCloud PVC (mover pod + tar stream, retried) |
| 41 | `41-migrate-bigvol.sh …` | Same, sharded and parallel, for the multi-TiB immutable stores (ClickHouse, RocksDB) |
| 50 | `50-scale-up.sh <ns>` | Restore original replicas after the data is in place |
| 60 | `60-resume.sh` | Bring the already-migrated stack up on a fresh host from `cluster-data/` + `deploy/` (runs the middleware if needed) |

Adding a second application means a new directory here with its own manifests or Helm
values. It should need nothing from `platform/`; if it does, that is a gap in the
middleware contract, not something to hard-code.
