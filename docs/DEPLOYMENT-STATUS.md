# Deployment status

## Home desktop (15 GiB, i7-6700)

Updated 2026-07-03.

| Step | Status |
|---|---|
| Phase 0: libvirt/KVM stack (`scripts/00-prereqs.sh`) | ⬜ pending — needs sudo run |
| Red Hat pull secret at `~/pull-secret.txt` | ⬜ pending — download from <https://console.redhat.com/openshift/create/local> |
| `crc` binary installed (`~/.local/bin/crc`) | ✅ v2.62.0 (OpenShift 4.22.1) |
| `crc` configured (home profile: 6 vCPU / 10.5 GiB / 60 GiB, telemetry off) | ✅ |
| `crc setup` + first `crc start` | ⬜ blocked on the two pending items above |
| Phase 2+ (users, quotas, MinIO, NFS, LAN access) | ⬜ not started |

Note before first start: free up RAM (close browser/IDE) — the VM needs 10.5 GiB and the desktop typically leaves only ~7 GiB available.

## Office machine (32 GB, 22 TB)

Not started. Deploy with: clone this repo → `sudo bash scripts/00-prereqs.sh` → save pull secret → `bash scripts/01-install-crc.sh` (auto-selects the office profile: 6 vCPU / 18 GiB / 120 GiB).
