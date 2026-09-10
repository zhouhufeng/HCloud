# Deployment status

Dated record of what is up where. Newest first. Platform pages: `docs/platforms/`.

## 2026-09-10 — repository reorganised around the middleware model

HCloud is now explicitly three layers — `platform/` (hosting), `hcloud/` (K3s
middleware), `apps/` (workloads); see `docs/ARCHITECTURE.md`. The K3s middleware
scripts (`hcloud/10`–`15`) were derived from the validated RKE2 and CRC scripts and
have **not yet run end to end on hardware**; their first run is the Dell MX7000
bring-up. Nothing changed on the running `pc` or Mac clusters.

| Platform | Status |
|---|---|
| Linux `pc` (RKE2) | ✅ running; ~7.1 TiB staging copy on HSA (ES big indices + ClickHouse tail outstanding) |
| Mac Studio (CRC) | ✅ cluster up 2026-07-28; proof-of-concept, superseded by K3s |
| Dell MX7000 | racked at HSPH IT; bring-up pending (bare-metal K3s or OpenStack VMs) |

## Mac Studio — proof-of-concept, OpenShift/CRC flavour (started 2026-07-26)

Apple Silicon Ultra, 20 cores, 128 GiB RAM, 20 TiB Thunderbolt volume `/Volumes/HSZ`.
Goal at the time: full NERC replacement incl. public website hosting. Runbook (scripts now
under `platform/mac/crc/`, renumbered 10–18): `docs/platforms/mac-studio.md`.

| Step | Status |
|---|---|
| CLI tools (oc 4.22, kubectl, helm, cloudflared, jq, htpasswd) | ✅ 2026-07-17 |
| CRC 2.62.0 installed (official pkg, GUI installer) | ✅ 2026-07-26 |
| Red Hat pull secret at `docs/Secretes/pull-secret.txt` | ✅ 2026-07-26 |
| `~/.crc` relocated to `/Volumes/HSZ/.crc` (symlink) | ✅ 2026-07-26 |
| CRC configured: mac-studio profile 16 vCPU / 96 GiB / 4 TiB, monitoring on | ✅ 2026-07-26 |
| `crc setup` + first `crc start` | ⏳ in progress 2026-07-26 (bundle download) |
| NERC export of `favor-4ee4be` (manifests, git-ignored) | ✅ fresh as of 2026-07-26 |
| Manifests converted for CRC (`docs/Secretes/migration/favor-4ee4be/crc/`) | ✅ 2026-07-26 |
| Apply manifests + storage parity (14) + users (15) + services (16) | ⬜ after cluster Ready |
| PVC data rsync from NERC (~8.1 TiB, script 18) | ⬜ needs fresh NERC token on the day |
| Public serving: Cloudflare Tunnel (12) + cert-manager (13) | ⬜ needs domain + `cloudflared tunnel login` + CF API token |
| Cutover + scale-up + NERC token rotation | ⬜ |


## Linux `pc` — proof-of-concept (detected 2026-07-04; CRC era, later replaced by RKE2)

Detected hardware does **not** match the earlier "home desktop (15 GiB, i7-6700)"
record below. Actual specs on this box:

| | Detected |
|---|---|
| CPU | 12th Gen i7-12700 — 20 threads, VT-x ✓ |
| Host RAM | 31 GiB |
| Storage | 22 TB (5.5 TB `sda` + 16.4 TB `sdb`) + 476 GB NVMe root (292 GB free) |
| Profile | **office** (host ≥ 24 GB) → 6 vCPU / 18 GiB / 120 GiB VM |

| Step | Status |
|---|---|
| `crc` binary installed (`~/.local/bin/crc`) | ✅ v2.62.0 (OpenShift 4.22.1) — installed 2026-07-04 |
| `crc` configured (6 vCPU / 18 GiB / 120 GiB, telemetry off) | ✅ pull-secret path repointed to this repo's `docs/Secretes/pull-secret.txt` 2026-07-09 |
| Phase 0: libvirt/KVM stack (`platform/legacy/crc-linux/00-prereqs.sh`) | ✅ 2026-07-09 — user in `libvirt` group, `libvirtd` socket-activated |
| Red Hat pull secret | ✅ present at `docs/Secretes/pull-secret.txt` (git-ignored) |
| virtiofsd (not packaged on Ubuntu 24.04) | ✅ 2026-07-09 — Debian 1.13.2 binary + `50-virtiofsd.json` descriptor installed (see note) |
| `crc setup` + first `crc start` | ✅ 2026-07-09 — cluster **Ready**, ClusterVersion 4.22.1 Available, all operators healthy |
| Phase 2+ (users, quotas, MinIO, NFS, LAN access) | ⬜ not started |

**Cluster is up (2026-07-09).** Console <https://console-openshift-console.apps-crc.testing>.
Credentials are in `docs/Secretes/cluster-credentials.txt` (git-ignored) — never commit them.

### One-time follow-up: `crc` CLI can't reach libvirt until re-login
The user was added to `libvirt` today but hasn't logged out/in, so the
`crc-daemon` **user** service (started at login) lacks the group and every
`crc ...` CLI command returns *"Unable to connect to kvm driver"*. The cluster
itself is unaffected. **Fix: log out and back in once** (or reboot); the daemon
then restarts with the group and `crc start/stop/status/console/oc-env` all work.
Until then, use the bundled `oc` directly:
`~/.crc/cache/crc_libvirt_4.22.1_amd64/oc --kubeconfig ~/.crc/machines/crc/kubeconfig get nodes`.

### Ubuntu 24.04 gotchas fixed this deploy
- `platform/legacy/crc-linux/00-prereqs.sh` no longer hard-fails on the missing `virtiofsd`
  package (`qemu-kvm` → `qemu-system-x86`; `virtiofsd` is best-effort).
- **virtiofsd is required at VM start** (libvirt's vhost-user-fs device), but
  Ubuntu 24.04 ships no package. Installed Debian trixie's binary to
  `/usr/libexec/virtiofsd` **and** its descriptor `/usr/share/qemu/vhost-user/50-virtiofsd.json`
  — libvirt discovers virtiofsd via that JSON, so both files are needed.

Note before start: the office VM needs 18 GiB. Free RAM is tight on this box —
close heavy desktop apps (Chrome/Edge/Zoom/WeChat) before `crc start`.

## Earlier record — Home desktop (15 GiB, i7-6700) — stale

Kept for history; the machine above did not match this. Claimed "crc installed +
configured" but neither was present on `pc` as of 2026-07-04.

## Office machine (32 GB, 22 TB) — CRC-era instructions, archived

Legacy path: `platform/legacy/crc-linux/00-prereqs.sh` → pull secret →
`01-install-crc.sh`. Superseded by RKE2 on this box and by the K3s middleware everywhere.
