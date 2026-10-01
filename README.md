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
   proof-of-concept, not as a target — the full reasoning is in
   [K3s vs OpenShift vs OKD](#k3s-vs-openshift-vs-okd) below.
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

## K3s vs OpenShift vs OKD

Philosophy point 3 says "plain Kubernetes, one distribution". This is the reasoning behind
it, in one place, so the choice can be re-argued later without re-deriving it. All three
are certified Kubernetes — the difference is not *what the API can express*, it is how much
platform arrives with it, who pays for that, and who is on the hook when it breaks.

| Dimension | **K3s** (the standard) | **OpenShift** (OCP) | **OKD** (community OpenShift) |
|---|---|---|---|
| What it is | Certified-conformant Kubernetes in one ~70 MB binary; Rancher/SUSE, donated to the CNCF | Red Hat's Kubernetes *product*: cluster + console + operators + registry + builds + monitoring | The upstream community build of the same product, minus the subscription |
| Cost | Free; optional SUSE support | Paid subscription (per core-pair / socket-pair, annual) | Free |
| Control-plane footprint | ~512 MiB–1 GiB per server node | 3 control-plane nodes, ~4 vCPU / 16 GiB each, before a single workload | Same as OCP — the architecture is identical |
| Smallest real cluster | A 2 GiB VM | 3 + 2 nodes (single-node OpenShift: ~8 vCPU / 16 GiB / 120 GB) | 3 + 2 nodes; SNO support lags |
| Bring-up | `curl … \| sh` + a join token; minutes | IPI/UPI installer wanting DNS, load balancers, and supported infra; hours to days | Same installer, fewer paved paths |
| Node OS | Any Linux you already run | RHCOS only — immutable, managed by the cluster, not by you | Fedora CoreOS (newer streams: CentOS Stream CoreOS) |
| API surface | Upstream only | Upstream **plus** Routes, SCCs, DeploymentConfigs, ImageStreams, BuildConfigs | Same as OCP |
| Multi-tenancy | Namespaces + quotas you write (`hcloud/14-tenants.sh`) | Projects, an integrated OAuth/console, group RBAC out of the box | Same as OCP |
| Security default | Permissive; Pod Security Admission is yours to set | SCCs: non-root, random UIDs, enforced by default | Same as OCP |
| Operators | Helm; install what you want | OLM + a curated, certified operator catalog | OLM + community catalog; certified Red Hat operators often absent |
| Registry & builds | Bring your own | Integrated registry, S2I builds, ImageStream triggers | Same as OCP |
| Monitoring | You install it (`hcloud/15-monitoring.sh`) | Prometheus/Alertmanager/console dashboards, preinstalled and supported | Preinstalled, community-supported |
| Storage | Whatever CSI you point at it | ODF (Ceph) as a supported product | Roll your own Rook/Ceph; ODF is not supported here |
| Upgrades | Swap the binary, or system-upgrade-controller | Cluster Version Operator drives the whole platform on Red Hat's channel | Community channels, slower and less reliable errata |
| Support | Community (or SUSE) | Red Hat SLA, compliance attestations (FIPS, CIS, FedRAMP) | Community mailing list and GitHub |
| Who operates it | Us | Us, but with a vendor to escalate to | Us, alone |

### K3s — advantages, then limitations

**Advantages.** It fits every host in `platform/`: a 31 GiB desktop, a Lima VM on the Mac,
an OpenStack guest, a blade. One binary and a token mean adding the second and third
MX7000 sled is a `HCLOUD_HA=true` re-run, not a project. Nothing is hidden — the ingress,
the storage classes and the tunnel are ours, installed identically everywhere, which is
exactly what makes the middleware contract portable. Upstream Helm charts work unmodified.
Bring-up is minutes, so a wrong answer is cheap to throw away.

**Limitations, stated plainly.** Everything above the kubelet is our labour: ingress, TLS,
tenants, monitoring, backup, upgrades — `hcloud/1x` exists *because* K3s ships none of it.
There is no console for collaborators, no operator catalog, no registry, no build system;
NERC's one BuildConfig and two ImageStreams have no equivalent and the images are pulled
pre-built instead. Security is permissive until we harden it. The default SQLite datastore
is single-server; HA needs embedded etcd and three servers. And when it breaks at 2 a.m.,
there is no one to call.

### OpenShift — advantages, then limitations

**Advantages.** It is the platform NERC ran, so `favor-4ee4be` applies as-is: Routes, SCCs
and ImageStreams all resolve. Everything HCloud hand-builds arrives integrated and
supported — console, OAuth, projects, monitoring, logging, ODF, a certified operator
catalog. Secure-by-default SCCs are a real advantage on a shared research platform. It
carries a vendor SLA and compliance attestations, which matter if grant or IRB terms ever
demand them.

**Limitations.** The subscription is a recurring cost against a one-time $150k capital
purchase. The footprint is the harder problem: three control-plane nodes at ~16 GiB each
is more than the entire Linux `pc`, and on the MX7000 it spends production RAM on the
platform itself. RHCOS means the sleds stop being machines we administer. The installer
wants infrastructure we would have to build to suit it. SCCs break upstream charts that
assume root or a fixed UID. And the API extensions are lock-in — the same lock-in that
`apps/nerc-migration/20-convert-manifests.py` was written to pay off once.

### OKD — advantages, then limitations

**Advantages.** OpenShift's architecture and API without the subscription: Routes, SCCs,
OLM, console, S2I and the integrated registry, at zero licence cost. It is the honest
choice if API parity with NERC is the goal — and the natural big brother to the validated
CRC proof-of-concept in `platform/mac/crc/`.

**Limitations.** It takes on OpenShift's full weight and gives back the one thing that
justifies it. No support contract, no compliance attestations, no certified operators; ODF
is unavailable, so the storage layer is self-run Rook/Ceph on top of an already heavy
platform. Releases trail OCP and the upgrade channels are materially less reliable —
upgrades are the part of OpenShift you least want to debug alone. Troubleshooting is
community-sourced and the documentation frequently describes OCP, not OKD.

### The decision, and what would reverse it

K3s wins here because of *who runs this*: one maintainer, ~7–8 TiB of data, and a fixed
budget better spent on NVMe and a GPU sled than on control-plane RAM or a subscription.
The single strongest argument for OpenShift/OKD — "the NERC manifests apply unchanged" —
was spent the day the conversion was scripted. What is left is a platform we would operate
alone (OKD), or pay for and still operate (OCP), whose integrated features are ones
`hcloud/1x` already delivers in ~6 scripts we can read. OpenShift Local survives as a
validated parity proof on the Mac Studio, not as a target.

Re-open the question if any of these become true: collaborators need self-service projects
and a console (today that need is met at the IaaS layer by
[`docs/platforms/openstack.md`](docs/platforms/openstack.md), not by the Kubernetes layer);
someone other than the maintainer must be able to run the cluster; a funder or IRB requires
supported, attested infrastructure; or operating the middleware ourselves starts costing
more time than a subscription would.

## Author

**zhouhufeng** — <zhouhufeng@gmail.com> — sole author and maintainer of HCloud.
