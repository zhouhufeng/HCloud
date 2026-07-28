# Mac Studio — HCloud runbook

The Mac Studio (Apple Silicon Ultra, 128 GiB RAM, 20 TiB on `/Volumes/HSZ`) is
the **primary production** HCloud target — the workstation that replaces the
terminating NERC OpenShift service. This runbook is the ordered path from a
fresh macOS to running the migrated `favor-4ee4be` workloads publicly.

## One-time prerequisites (manual, ~10 min)

1. **Red Hat pull secret.** Free developer account:
   <https://console.redhat.com/openshift/create/local> → download → save to
   `docs/Secretes/pull-secret.txt` (git-ignored). Without this you can still
   install CRC but cannot pull the Red Hat cluster bundle.
2. **Cloudflare public domain and API token.** Own a domain on Cloudflare
   (e.g. `hcloud.genohub.org`). Create an API token with `Zone.DNS:Edit` for
   that zone.
3. **Cloudflared login.** In a terminal: `cloudflared tunnel login` — this
   opens a browser and drops `~/.cloudflared/cert.pem`.

If any of these are missing when you run the scripts, the script fails at
exactly the point that needs it and tells you what to do.

## Bring-up order

Each script is idempotent. All install/state goes onto `/Volumes/HSZ`.

| # | Script | What it does | Approx time |
|---|---|---|---|
| 60 | `60-mac-prereqs.sh` | Homebrew + `crc` + `oc` + `helm` + `cloudflared` + `httpd`/`htpasswd` + `jq` | 5–10 min |
| 61 | `61-install-crc-mac.sh` | Symlinks `~/.crc` → `/Volumes/HSZ/.crc`; profiles CRC (16 vCPU / 96 GiB / 4 TiB); `crc setup` + `crc start` | 30–60 min (bundle download + boot) |
| 62 | `HCLOUD_TUNNEL_NAME=… HCLOUD_DOMAIN=… 62-cloudflared-tunnel.sh` | Cloudflare Tunnel as launchd, wildcard `*.<domain>` → CRC router | 2 min |
| 63 | `HCLOUD_CF_API_TOKEN=… HCLOUD_ACME_EMAIL=… HCLOUD_DOMAIN=… 63-cert-manager.sh` | cert-manager + Let's Encrypt wildcard cert | 5 min (DNS propagation) |
| 64 | `64-storage-parity.sh` | Adds a StorageClass alias `ocs-external-storagecluster-ceph-rbd`; MinIO operator | 2 min |
| 65 | `HCLOUD_USERS='alice bob' 65-users-quotas.sh` | HTPasswd IdP + per-user project + ResourceQuota + LimitRange | 2 min |
| 66 | `66-nerc-services.sh` | OpenShift Pipelines + Serverless + OpenDataHub (RHOAI upstream) | 10 min (operators install async) |
| 67 | `67-migrate-to-crc.py --ns favor-4ee4be` | Convert NERC raw exports → apply-ready CRC manifests | 5 sec |
| — | `oc apply -f docs/Secretes/migration/favor-4ee4be/crc/` | Apply the converted manifests (PVCs bind; workloads at replicas: 0) | 30 sec |
| 68 | `NERC_KUBECONFIG=… LOCAL_KUBECONFIG=… 68-rsync-nerc-data.sh favor-4ee4be` | Copy every PVC's data via helper pods, NERC → local | **hours** (≈8 TB) |
| 69 | `69-scale-up.sh favor-4ee4be` | Restore original replica counts from `_replicas.json` | 30 sec |

## The favor-4ee4be workload — what will land here

Exported 2026-07-09 while NERC was still up:

```
StatefulSets  : api, elasticsearch-autocomplete-es-default (×2),
                hg38-clickhouse, higlass, nats, postgres, rocksdb-index-service
Deployments   : batch-worker (2), jaeger, minio-deployment, nats-box (0/0)
Routes        : 11  (incl. custom domain api-v2.genohub.org)
Services      : 24  (many headless)
Secrets/CMs   : 44 secrets, 25 configmaps
Roles / RBs   : 4 roles, 14 rolebindings
Image build   : 1 BuildConfig, 2 ImageStreams (higlass-server, hg38-migration)
```

PVCs and their sizes (this is where the 8 TB lives):

| PVC | Size |
|---|---|
| `api-cache-api-0` | 500Mi |
| `data-hg38-clickhouse-0` | 2600Gi |
| `data-postgres-0` | 50Gi |
| `elasticsearch-data-elasticsearch-autocomplete-es-default-0` | 115Gi |
| `elasticsearch-data-elasticsearch-autocomplete-es-default-1` | 115Gi |
| `hg38-rocksdb` | 2Ti |
| `higlass-data` | 100Gi |
| `kuzu-data-api-0` | 30Gi |
| `minio-pvc` | 3Ti |

Sum ≈ 8.1 TiB. All go onto `/Volumes/HSZ` via the CRC-disk relocation.

## Route hosts after migration

The converter rewrites Route hosts using `HCLOUD_DOMAIN`:

```
Before (NERC)                                        After (HCloud, HCLOUD_DOMAIN=hcloud.example)
────────────────────────────────────────────────────────────────────────────────────────────────
api-favor-4ee4be.apps.shift.nerc.mghpcc.org       →  api.hcloud.example
higlass-favor-4ee4be.apps.shift.nerc.mghpcc.org   →  higlass.hcloud.example
minio-s3-favor-4ee4be.apps.shift.nerc.mghpcc.org  →  minio-s3.hcloud.example
api-v2.genohub.org  (custom-domain)               →  api-v2.hcloud.example
```

To keep `api-v2.genohub.org` **as-is** (recommended — external clients point at it):

- Add another `cloudflared tunnel route dns` for `api-v2.genohub.org` (needs
  `genohub.org` on Cloudflare too).
- Add another Ingress rule in `~/.cloudflared/config.yml` for that hostname.
- Then apply the un-rewritten route: run `67-migrate-to-crc.py` with an empty
  `HCLOUD_DOMAIN` to keep hosts, or hand-edit `30-routes.yaml` before apply.

## Honest limits vs NERC (things this Mac cannot do)

1. **No GPU workloads.** Apple Metal is not exposed to Linux containers via
   vfkit; the NVIDIA GPU operator won't work. CPU-only notebooks are fine.
2. **RWX volumes not offered.** Same as NERC — RWO only. Use MinIO S3 for
   multi-writer data.
3. **CILogon federated login is not wired.** Users log in with local htpasswd
   (script 65). Wire Keycloak+CILogon after public serving is up (needs a
   real HTTPS callback URL).
4. **OpenStack VMs.** Not present; use OpenShift Virtualization (KubeVirt) if
   you need this — separate follow-up.
5. **Multi-node HA.** Single-node cluster on one Mac. Backups matter more here
   than on multi-node; snapshot `/Volumes/HSZ/.crc` before major changes.

## Cutover sequence (when everything is ready)

1. Run 60 → 66 on the Mac. Verify `oc get nodes` shows the local cluster Ready.
2. Run 67 to convert manifests. Run `oc apply -f .../crc/` — pods come up at
   replicas: 0, PVCs bind.
3. Kick off 68 in a nohup / tmux — it will run for many hours copying the
   PVCs. Use `du -sh /Volumes/HSZ/.crc/machines/crc/` to watch disk grow.
4. Optional: run 68 again for a fast incremental catchup right before cutover.
5. On NERC: scale everything to 0 (`oc scale --replicas=0 --all`).
6. On the Mac: run 69 to scale up. Verify each Route responds on
   `<name>.<HCLOUD_DOMAIN>`.
7. **Rotate the NERC API token** (see `docs/Secretes/nerc-login.txt`).
8. Delete the NERC allocation when confident.
