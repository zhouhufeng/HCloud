# HCloud — A Local Private Cloud for Harvard, Powered by OpenShift

HCloud is a self-hosted replacement for the terminating [NERC (New England Research Cloud)](https://nerc-project.github.io/nerc-docs/) platform. It runs a **real OpenShift 4.x cluster on this workstation, alongside the existing Ubuntu desktop**, so NERC pods, services, and workflows can be migrated and kept running locally.

## Is this possible on this machine?

**Yes — with honest limits.** The approach is **OpenShift Local (CRC)**: a genuine single-node OpenShift cluster inside a KVM virtual machine. You boot it when you need it (`crc start`) and shut it down when you don't (`crc stop`), and Ubuntu stays untouched. Everything NERC-critical for migration testing works: the OpenShift web console, `oc` CLI, Deployments/Services/Routes, the internal image registry, RBAC, projects and quotas.

### This machine vs. the plan

| Resource | This workstation | What HCloud uses | Verdict |
|---|---|---|---|
| CPU | i7-6700 — 4 cores / 8 threads, VT-x ✓ | 6 vCPU for the cluster VM | OK |
| RAM | 15 GiB (desktop uses ~8 GiB) | 10–11 GiB for the cluster VM | **Tight — close heavy apps (browser, IDE) before `crc start`** |
| Disk | 82 GiB free on `/` (SSD), 208 GiB on SSN SSD, 1.8 TB + 5.5 TB HDDs | ~40 GiB for cluster VM; HDDs for S3/NFS bulk storage | OK |
| GPU | GTX 1080 (drives the display) | Not available inside the cluster initially | See Phase 5 |
| KVM | `/dev/kvm` present | libvirt/qemu (Phase 0 installs it) | OK |

### Honest limits (read before deploying)

1. **Concurrency, not head-count, is the limit.** 10+ department users can have accounts, projects, and quotas — but only ~2–3 can run real workloads *at the same time* on 4 cores / 11 GiB. This is a migration target and pilot platform, not a production datacenter.
2. **RAM is the binding constraint.** The i7-6700 supports up to 64 GB DDR4; a ~$60–100 upgrade to 32–64 GB is the single highest-leverage improvement and unlocks Phases 5–6.
3. **OpenStack-style VMs (OpenShift Virtualization) need nested virtualization inside an already-tight VM** — deferred to Phase 6 (after RAM upgrade).
4. **GPU notebooks** require passing the GTX 1080 into the cluster VM (VFIO) and moving the desktop display to the Intel HD 530 iGPU — doable, but optional Phase 5.
5. CRC is licensed/designed by Red Hat as a development/testing cluster. For a department-grade deployment later, Phase 6 moves the same manifests to multi-node **OKD** on real server hardware — nothing built here is throwaway.

---

## NERC feature mapping

| NERC service | HCloud equivalent | Phase |
|---|---|---|
| OpenShift container platform | OpenShift Local (CRC) single-node cluster | 1 |
| Web console, `oc`, Routes, builds | Included in CRC | 1 |
| Projects, quotas, RBAC, multi-user | htpasswd users + per-project ResourceQuotas | 2 |
| Object storage (S3 / Swift) | MinIO on the 5.5 TB HDD, exposed to cluster + LAN | 2 |
| Shared filesystems (NFS) | NFS export from host HDDs into cluster PVs | 2 |
| Your NERC pods & services | Migrated via manifest export + image mirroring | 3 |
| RHOAI / JupyterLab workbenches | JupyterHub on the cluster (CPU first) | 4 |
| GPU workloads | GTX 1080 via VFIO passthrough + NVIDIA GPU operator | 5 (optional) |
| Keycloak SSO | Keycloak operator, replaces htpasswd | 6 |
| OpenStack VMs | OpenShift Virtualization (KubeVirt) | 6 (needs RAM) |
| ColdFront allocations | ColdFront container pointed at the cluster | 6 |

---

## Deployment plan

### Phase 0 — Prepare the host (~15 min, needs sudo)

1. Install virtualization stack: `libvirt-daemon-system`, `qemu-kvm`, `virt-manager`, and NetworkManager integration. → `scripts/00-prereqs.sh`
2. Add user to `libvirt` group (re-login required).
3. **Manual step (only you can do this):** get a free Red Hat pull secret — create a no-cost Red Hat developer account and download the pull secret from <https://console.redhat.com/openshift/create/local>. Save it as `~/pull-secret.txt`. *(Fallback if account creation is a problem: the OKD preset needs no pull secret but tracks community builds.)*
4. Free up RAM: the desktop currently uses ~8 GiB with swap already under pressure — close browsers/IDEs before starting the cluster.

### Phase 1 — Install and start OpenShift (~30–60 min, mostly download)

1. Download the `crc` binary from the public OpenShift mirror. → `scripts/01-install-crc.sh`
2. Configure the cluster VM: 6 vCPU, 10.5 GiB RAM, 60 GiB disk (kept on `/`; relocatable to the SSN SSD via symlinking `~/.crc`).
3. `crc setup` (one-time host prep) then `crc start -p ~/pull-secret.txt`.
4. Verify: log into the console at `https://console-openshift-console.apps-crc.testing` (credentials from `crc console --credentials`) and run `oc get nodes`.

**Daily driving:** `crc start` to boot HCloud, `crc stop` to get your RAM back. State persists across stops.

### Phase 2 — Make it a platform, not just a cluster

1. **Users:** create htpasswd identity provider; one account per department user; remove kubeadmin from daily use. → `manifests/users/`
2. **Projects & quotas:** per-user/per-group projects with `ResourceQuota` + `LimitRange` mirroring NERC's allocation feel. → `manifests/quotas/`
3. **Object storage:** MinIO running on the host (systemd) with data on the 5.5 TB HDD (`/dev/sdd`), S3 API reachable from cluster pods and the LAN — replaces NERC's Swift/S3.
4. **Shared storage:** NFS export from the 1.8 TB HDD; `nfs-subdir-external-provisioner` in-cluster so PVCs "just work".
5. **LAN access for department users:** CRC binds to localhost by default; an HAProxy reverse proxy on the host forwards ports 80/443/6443 so colleagues on the Harvard network reach the console, API, and app routes from their own machines. → `scripts/20-lan-access.sh`

### Phase 3 — Migrate pods & services from NERC

Do this **before NERC terminates** — the source cluster must still be reachable.

1. **Inventory:** `oc get all,cm,secret,pvc,route -o yaml` per NERC namespace → `migration/<namespace>/` in this repo. → `scripts/30-export-nerc.sh`
2. **Images:** mirror container images from NERC's internal registry (and any external registries) to HCloud's internal registry with `skopeo copy` / `oc image mirror`.
3. **Manifests:** scrub cluster-specific fields (UIDs, clusterIP, NERC route hosts, storage classes) and re-apply to HCloud projects. Route hosts become `*.apps-crc.testing` (or a LAN domain via nip.io).
4. **Data:** for each NERC PVC, `oc rsync` the data out of a running pod on NERC and into the matching pod/PVC on HCloud.
5. **Verify:** every migrated service answers on its new route; document per-service results in `migration/REPORT.md`.

### Phase 4 — Jupyter/ML workbenches (NERC RHOAI feel)

1. Deploy **JupyterHub** (zero-to-jupyterhub Helm chart) on the cluster with per-user notebook pods, CPU-only at first, home directories on the NFS provisioner.
2. Culling/idle timeouts so notebooks release the scarce RAM.

### Phase 5 — GPU (optional, invasive)

1. Move the Ubuntu display to the Intel HD 530 iGPU (BIOS setting + Xorg config).
2. Bind the GTX 1080 to VFIO and pass it through to the cluster VM.
3. Install the NVIDIA GPU operator; expose the GPU to JupyterHub profiles.
   *Skip this phase if desktop stability matters more than in-cluster GPU.*

### Phase 6 — Scale beyond this box (when hardware/RAM arrives)

1. RAM to 64 GB → raise cluster VM to 32+ GiB; enable **OpenShift Virtualization** for OpenStack-style user VMs.
2. **Keycloak** SSO (replacing htpasswd) and **ColdFront** for NERC-style allocation management.
3. Additional machines → migrate the same manifests from CRC to a multi-node **OKD** cluster. Everything in `manifests/` is portable by design.

---

## Repository layout

```
README.md            ← this plan
scripts/             ← numbered, idempotent setup scripts (run in order)
manifests/           ← Kubernetes/OpenShift YAML applied to the cluster (portable to OKD later)
migration/           ← exported NERC namespaces + migration report
docs/                ← runbooks: daily ops, troubleshooting, LAN access
```

## Quick start (once Phase 0–1 are done)

```bash
crc start                      # boot HCloud
eval $(crc oc-env)             # get the oc CLI on PATH
oc get nodes                   # verify
crc console                    # open the web console
crc stop                       # shut down, reclaim RAM
```
