# `hcloud/` — the middleware layer

This directory **is HCloud**. Everything here runs identically on any Linux host the
[platform layer](../platform/README.md) hands over — bare metal in the server room, an
OpenStack or AWS VM, or a Linux VM on a Mac — and produces the same cluster contract for
the [application layer](../apps/README.md) to build on.

Rules for this directory:

- Scripts read **only** `hcloud/hcloud.env` (the platform contract, see
  [`hcloud.env.example`](hcloud.env.example)) and talk to the cluster **only** through
  `kubectl` and `helm`. No `oc`, no `crc`, no `virsh`, no cloud CLI.
- Nothing here may mention a hosting platform. Platform-specific flags travel in
  `HCLOUD_K8S_EXTRA_ARGS`; platform-specific add-ons live under `platform/<name>/`.
- Every script is idempotent and safe to re-run.

## Bring-up order

| # | Script | Produces (the contract the apps layer relies on) |
|---|---|---|
| 10 | `10-install-k8s.sh` | Kubernetes: **K3s** (standard) or RKE2; server or agent; optional 3-server embedded etcd. Bundled ingress disabled |
| 11 | `11-storage.sh` | StorageClasses `local-path` (default, under `HCLOUD_STORAGE_DIR`), `hcloud-data` (static PVs for migrated data), `ocs-external-storagecluster-ceph-rbd` (NERC name alias) |
| 12 | `12-ingress-tls.sh` | ingress-nginx as the default IngressClass `nginx` with SSL passthrough; with `HCLOUD_DOMAIN`: cert-manager + Let's Encrypt wildcard `*.HCLOUD_DOMAIN` as the default certificate |
| 13 | `13-public-tunnel.sh` | cloudflared **inside the cluster** → every Ingress host under `HCLOUD_DOMAIN` is public, no static IP or open port on any platform |
| 14 | `14-tenants.sh` | Per-user namespace + ResourceQuota + LimitRange + admin kubeconfig (`docs/Secretes/users/`) |
| 15 | `15-monitoring.sh` | kube-prometheus-stack; Grafana at `grafana.HCLOUD_DOMAIN` |

```bash
cp hcloud/hcloud.env.example hcloud/hcloud.env   # or let platform/<x>/10-*.sh write it
$EDITOR hcloud/hcloud.env
for s in hcloud/1[0-5]-*.sh; do bash "$s"; done
```

Multi-node: run `10-install-k8s.sh` on the first server, copy
`docs/Secretes/k8s-node-token` to each other node, set `HCLOUD_NODE_ROLE` /
`HCLOUD_SERVER_URL` in that node's `hcloud.env`, run `10-install-k8s.sh` there. Steps
11–15 run once, from any server.

## What the applications may assume

- IngressClass `nginx` exists and is default; an Ingress with host `x.HCLOUD_DOMAIN`
  is reachable publicly over HTTPS with a valid certificate, no TLS block needed.
- StorageClasses `local-path` (default), `hcloud-data`, `ocs-external-storagecluster-ceph-rbd`.
- `kubectl` on a server node works with `KUBECONFIG=/etc/rancher/k3s/k3s.yaml`
  (`/etc/rancher/rke2/rke2.yaml` on RKE2).
- Nothing else. In particular no OpenShift API objects (Route, BuildConfig, ImageStream,
  SCC) — the apps layer converts those (`apps/nerc-migration/20-convert-manifests.py`).

## Why K3s

The migration path is fully scripted, so OpenShift's operators and console earn nothing
on hardware we own. K3s is a single binary, CNCF-conformant, joins nodes with one command,
and runs from a 2 GB VM up to a blade chassis. RKE2 is retained as an option because the
Linux `pc` proof-of-concept and its 7 TiB of migrated data run on it today; the two share
the `/etc/rancher/<distro>/` layout so the rest of the layer does not care. OpenShift
survives only in the Mac CRC proof-of-concept under `platform/mac/crc/`.
