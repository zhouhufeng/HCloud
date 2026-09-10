# HCloud architecture — a middleware, not a machine

HCloud began as "the NERC replacement on the hardware we have". Running it on a Linux
desktop, then a Mac Studio, and designing it for the purchased Dell blades made the real
shape obvious: the thing that stays constant is **a K3s cluster configured a particular
way**, and everything below it is interchangeable. This document fixes that shape.

## The three layers

| Layer | Directory | Owns | Must not know about |
|---|---|---|---|
| **Applications** | `apps/` | manifests, data migration, replica counts, application config | the hosting platform, the Kubernetes distribution, how TLS or public DNS work |
| **HCloud middleware** | `hcloud/` | Kubernetes install, storage classes, ingress, certificates, public tunnel, tenants, monitoring | which platform it is on (no `oc`, `crc`, `virsh`, `aws`, `openstack` calls) |
| **Hosting platform** | `platform/` | provisioning hosts, disks, networks; platform-native add-ons (CSI, cloud LB, GPU) | the applications |

Each layer talks to the one below through a contract, and only through it.

### Contract 1 — platform → middleware (`hcloud/hcloud.env`)

The platform hands over one or more Linux hosts and a small environment file
([`hcloud/hcloud.env.example`](../hcloud/hcloud.env.example)). The variables that matter:

| Variable | Meaning |
|---|---|
| `HCLOUD_K8S_DISTRO` | `k3s` (standard) or `rke2` |
| `HCLOUD_NODE_ROLE`, `HCLOUD_HA`, `HCLOUD_SERVER_URL` | single node, 3-server embedded etcd, or joiner |
| `HCLOUD_STORAGE_DIR` | the mounted data directory — an HDD, an NVMe RAID10, a Cinder or EBS volume; the middleware does not care |
| `HCLOUD_K8S_EXTRA_ARGS` | the *only* place platform-specific Kubernetes flags may appear (e.g. `--kubelet-arg cloud-provider=external` on OpenStack) |
| `HCLOUD_DOMAIN`, `HCLOUD_ACME_EMAIL`, `HCLOUD_TUNNEL_NAME` | the public identity; empty domain = LAN-only cluster |
| `HCLOUD_USERS`, `HCLOUD_Q_*` | tenants and their quotas |

Secrets (node token, Cloudflare API token, tunnel credentials) live under the git-ignored
`docs/Secretes/` and are read by file name, never passed on command lines.

### Contract 2 — middleware → applications (the cluster)

| Guarantee | Provided by |
|---|---|
| IngressClass `nginx`, default; SSL passthrough available | `12-ingress-tls.sh` |
| Any Ingress host under `HCLOUD_DOMAIN` is public over HTTPS with a valid certificate, with no TLS block in the Ingress | `12-ingress-tls.sh` (wildcard default cert) + `13-public-tunnel.sh` |
| StorageClass `local-path` (default) on `HCLOUD_STORAGE_DIR` | `11-storage.sh` |
| StorageClass `hcloud-data` for static PVs (migrated data) | `11-storage.sh`; used by `apps/…/60-resume.sh` |
| StorageClass `ocs-external-storagecluster-ceph-rbd` (NERC's name) resolves to something | `11-storage.sh` (alias → local-path; OpenStack add-on → Cinder) |
| One namespace per tenant with ResourceQuota, LimitRange, admin kubeconfig | `14-tenants.sh` |
| Prometheus/Grafana | `15-monitoring.sh` |
| `kubectl` from a server node via the distro kubeconfig | `10-install-k8s.sh` |

Anything an application needs that is not in this table is a request to extend the
middleware, not something to solve per platform.

## Decisions

**K3s is the Kubernetes.** CNCF-conformant, one binary, one-command joins, runs from a
2 GB VM to a blade chassis. The migration path being fully scripted removed the case for
OpenShift's operators and console. RKE2 stays selectable because the Linux `pc`
proof-of-concept and its data run on it; the two share `/etc/rancher/<distro>/`, so the
layer needs one `case` statement to support both. CRC/OpenShift remains only in
`platform/mac/crc/` as a validated but superseded flavour.

**One ingress, installed by us.** The bundled ingress (traefik on K3s, rke2-ingress-nginx
on RKE2) is disabled so ingress-nginx is installed and configured identically everywhere,
including SSL passthrough and the wildcard default certificate. The converted NERC Routes
target exactly that.

**cloudflared runs in-cluster.** The earlier Mac path ran it as a host daemon
(launchd). As a Deployment it is the same YAML on every platform, has no host dependency,
and is what makes "no inbound port, no static IP" true on a desktop behind NAT, a VM
without a floating IP, and a blade in the server room alike.

**Storage is a directory.** `local-path` on `HCLOUD_STORAGE_DIR` is the baseline because
it is the fastest possible PV (a directory on the disk the platform chose) and the
databases do heavy random I/O. Replicated/movable storage (Cinder on OpenStack, Longhorn
across blades) is a platform add-on that re-points the NERC alias class; the databases
should stay on node-local NVMe regardless (see `docs/platforms/openstack.md` §6).

**Data and secrets travel on the drive, not in git.** `cluster-data/<pvc>/` and
`docs/Secretes/` are git-ignored; `apps/nerc-migration/60-resume.sh` rebuilds a running
stack from them on any platform. That, plus the scripts, is the whole disaster-recovery
story for a single-site deployment.

## Platform status

| Platform | Provisioning | Middleware exercised? | Notes |
|---|---|---|---|
| Linux bare metal (`pc`) | `platform/linux/` | ✅ RKE2 path, 7 TiB migrated | RAM-bound (31 GiB); `docs/platforms/linux-baremetal.md` |
| Mac Studio, CRC | `platform/mac/crc/` | n/a (OpenShift) | validated 2026-07; `docs/platforms/mac-studio.md` |
| Mac Studio, Lima + K3s | `platform/mac/10-lima-vm.sh` | ⬜ | reference; replaces CRC when needed |
| Dell MX7000, bare-metal K3s | `platform/linux/` per sled, `HCLOUD_HA=true` | ⬜ | fastest route to production; `docs/platforms/dell-mx7000.md` |
| Dell MX7000, OpenStack VMs | `platform/openstack/` | ⬜ | adds collaborator self-service at ~20 % RAM cost; `docs/platforms/openstack.md` |
| AWS EC2 | `platform/aws/` | ⬜ | reference / portability proof |

The K3s middleware scripts (`hcloud/1x`) were written in the 2026-09 reorganisation
from the validated RKE2 and CRC scripts; their first end-to-end run on real hardware is the
Dell bring-up. Treat "⬜" as *designed and reviewed, not yet run*.

## How to change things

- **New hosting platform** → `platform/<name>/`, a page in `docs/platforms/`, a row in the
  tables above. Do not touch `hcloud/`.
- **New capability every app should get** (e.g. an OIDC login, a backup operator) → a new
  `hcloud/1x-*.sh`, and a row in Contract 2.
- **New application** → `apps/<name>/`. If it needs something platform-specific, that is a
  contract gap; fix it in the middleware.
- **Platform-only extra** (GPU operator, cloud CSI, MetalLB) → `platform/<name>/2x-*.sh`,
  run after the middleware, leaving Contract 2 intact.
