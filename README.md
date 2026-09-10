# HCloud — Kubernetes middleware for the group's research platform

HCloud is the layer between **our applications** (the genohub.org stack migrated from
NERC: pods, services, databases, object storage, ~7–8 TiB of persistent volumes) and
**whatever is hosting them**. It installs and configures K3s on any Linux host and
delivers one fixed contract upward — ingress, TLS, a public domain, storage classes,
tenants, monitoring — so the applications never learn where they are running.

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  APPLICATIONS            apps/                                               │
│  favor-4ee4be (genohub.org): api, ClickHouse, Elasticsearch, MinIO, RocksDB, │
│  Postgres, Kuzu, HiGlass, workers · JupyterHub · future apps                 │
│  sees: Ingress (nginx) · *.HCLOUD_DOMAIN · StorageClasses · namespaces       │
├──────────────────────────────────────────────────────────────────────────────┤
│  HCLOUD MIDDLEWARE       hcloud/                                             │
│  K3s → storage classes → ingress-nginx + cert-manager → Cloudflare Tunnel    │
│  → tenants/quotas → monitoring.  Reads only hcloud.env. Uses only kubectl.   │
├──────────────────────────────────────────────────────────────────────────────┤
│  HOSTING PLATFORM        platform/                                           │
│  own hardware: Linux pc · Mac Studio (Lima VM / CRC) · Dell MX7000 blades    │
│  clouds:       OpenStack VMs (ours, on the MX7000) · AWS EC2                 │
│  delivers: a Linux host, a mounted data directory, outbound internet         │
└──────────────────────────────────────────────────────────────────────────────┘
```

## Development philosophy

1. **The platform is replaceable; the middleware is not.** Every hosting platform ends at
   the same point: a Linux host with a mounted data directory and a written
   `hcloud/hcloud.env`. From there `hcloud/` is identical everywhere. Moving HCloud from a
   31 GiB desktop to a $150k blade chassis or to a cloud VM is a change in `platform/`,
   never in `hcloud/` or `apps/`.
2. **Applications see a contract, not a cluster.** IngressClass `nginx`, a wildcard TLS
   certificate under `HCLOUD_DOMAIN`, the StorageClass names `local-path`, `hcloud-data`
   and NERC's `ocs-external-storagecluster-ceph-rbd`, per-tenant namespaces with quotas.
   Nothing OpenShift-specific survives: the apps layer converts Routes to Ingress once.
3. **Plain Kubernetes, one distribution.** K3s is the standard (RKE2 is kept only because
   the validated Linux proof-of-concept runs on it). OpenShift/CRC lives on as one Mac
   proof-of-concept, not as a target.
4. **Public without inbound.** cert-manager issues real certificates and cloudflared runs
   *inside* the cluster, so a laptop-class box behind NAT, a VM with no floating IP and a
   blade in the server room are all served the same way — no static IP, no open port.
5. **Everything is a numbered, idempotent script in git.** Data and secrets are not
   (`cluster-data/`, `docs/Secretes/`); they travel on the drive. A platform, a middleware
   step or an application is "done" when re-running its script changes nothing.

## Repository layout

```
platform/        Layer 1 — hosting platforms (get to a Linux host that meets the contract)
  linux/           any Linux host: bare metal (pc, Dell sled) or VM        ✅ validated
  mac/             Mac Studio: Lima Linux VM for K3s                       ⬜ reference
  mac/crc/         Mac Studio: OpenShift Local (CRC) proof-of-concept      ✅ validated 2026-07
  openstack/       OpenStack VMs (Terraform + Cinder CSI add-on)           ⬜ designed
  aws/             AWS EC2                                                 ⬜ reference
  legacy/          CRC on a Linux desktop (2026-07 experiments)            archived
hcloud/          Layer 2 — THE MIDDLEWARE: 10-install-k8s → 11-storage → 12-ingress-tls
                 → 13-public-tunnel → 14-tenants → 15-monitoring; hcloud.env.example = contract
apps/            Layer 3 — applications: nerc-migration/ (export, convert, apply, copy, scale, resume)
docs/
  ARCHITECTURE.md      the layered model, contract, and decisions
  MIGRATION.md         NERC → HCloud runbook, migration status, resume/port
  DEPLOYMENT-STATUS.md what is up where, dated
  platforms/           one page per hosting platform (linux-baremetal, mac-studio, dell-mx7000, openstack, aws)
docs/Secretes/   git-ignored: credentials, pull secret, NERC exports, converted manifests, kubeconfigs
cluster-data/    git-ignored: the migrated PVC data (~7 TiB), one directory per volume
```

## Quick start (any Linux host)

```bash
git clone <this repo> HCloud && cd HCloud
HCLOUD_STORAGE_DIR=/mnt/bigdisk bash platform/linux/10-host-prep.sh   # writes hcloud/hcloud.env
$EDITOR hcloud/hcloud.env                                              # HCLOUD_DOMAIN, HCLOUD_USERS, …
for s in hcloud/1[0-5]-*.sh; do bash "$s"; done                        # the middleware

# the NERC application
oc login <NERC>; bash apps/nerc-migration/10-export-nerc.sh favor-4ee4be
python3 apps/nerc-migration/20-convert-manifests.py --ns favor-4ee4be --domain "$HCLOUD_DOMAIN"
bash apps/nerc-migration/30-apply.sh favor-4ee4be
# copy data (40/41), then: bash apps/nerc-migration/50-scale-up.sh favor-4ee4be
```

Already have the migrated data on a drive? `bash apps/nerc-migration/60-resume.sh` does
middleware + PV binding + apply + scale-up in one go.

Other platforms: a Mac → `platform/mac/10-lima-vm.sh` first; OpenStack → `platform/openstack/`;
AWS → `platform/aws/10-ec2.sh`. Each ends at the same "any Linux host" quick start.

## Where HCloud runs today

| Platform | Middleware | What it proved / will prove | Status |
|---|---|---|---|
| Linux `pc` (i7-12700, 31 GiB, 22 TB HDD) | RKE2 + local-path | the full pipeline and ~7 TiB of NERC data migrated | ✅ running |
| Mac Studio (M-Ultra, 128 GiB, 20 TiB) | OpenShift Local (CRC) | an OpenShift-API-parity path; RAM headroom | ✅ cluster up 2026-07-28; superseded by K3s |
| **Dell MX7000 blades + storage rack** ($150k, racked at HSPH IT) | **K3s**, bare metal or on OpenStack VMs | the production platform: full stack concurrently, NVMe, GPU sled, 24/7 public serving | ⬜ bring-up next — `docs/platforms/dell-mx7000.md`, `docs/platforms/openstack.md` |
| AWS / other clouds | K3s on VMs | burst, staging, portability proof | ⬜ reference |

The $200k purchase ($150k hardware + $50k AI tooling) and its rationale are in
[`docs/platforms/dell-mx7000.md`](docs/platforms/dell-mx7000.md). The NERC comparison and
the honest trade-offs of self-operating the platform are in
[`docs/MIGRATION.md`](docs/MIGRATION.md).

## Author

**zhouhufeng** — <zhouhufeng@gmail.com> — sole author and maintainer of HCloud.
