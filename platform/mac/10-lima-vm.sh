#!/usr/bin/env bash
# Platform: Mac Studio · 10 — a Linux VM (Lima) that runs the K3s middleware.
#
# STATUS: reference implementation, not yet exercised on the Mac Studio (the validated
# Mac path so far is the OpenShift/CRC flavour under platform/mac/crc/). Apple Silicon
# cannot run Linux containers natively, so HCloud on a Mac is HCloud on a Linux VM.
#
#   HCLOUD_VM_NAME   (hcloud)  HCLOUD_VM_CPUS (16)  HCLOUD_VM_MEM_GIB (96)  HCLOUD_VM_DISK_GIB (4000)
#   HCLOUD_MAC_VOLUME (/Volumes/HSZ)  the 20 TiB Thunderbolt volume; mounted writable into the VM
#
# PV data goes on the VM's own (sparse) disk by default — virtiofs mounts are fine for the
# repo and staging copies but not for database PVs. Idempotent.
set -euo pipefail
[ "$(uname)" = Darwin ] || { echo "ERROR: macOS only"; exit 1; }
NAME="${HCLOUD_VM_NAME:-hcloud}"; CPUS="${HCLOUD_VM_CPUS:-16}"; MEM="${HCLOUD_VM_MEM_GIB:-96}"
DISK="${HCLOUD_VM_DISK_GIB:-4000}"; VOL="${HCLOUD_MAC_VOLUME:-/Volumes/HSZ}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

command -v brew >/dev/null || { echo "ERROR: install Homebrew first (https://brew.sh)"; exit 1; }
command -v limactl >/dev/null || { echo "==> Installing Lima"; brew install --quiet lima; }

if ! limactl list --json 2>/dev/null | grep -q "\"name\":\"$NAME\""; then
  echo "==> Creating VM $NAME: $CPUS vCPU / $MEM GiB / $DISK GiB (Ubuntu LTS, vz + virtiofs)"
  MOUNTS=(--mount "$REPO_ROOT:w")
  [ -d "$VOL" ] && MOUNTS+=(--mount "$VOL:w")
  limactl create --name="$NAME" --tty=false --vm-type=vz --mount-type=virtiofs \
    --cpus="$CPUS" --memory="$MEM" --disk="$DISK" "${MOUNTS[@]}" template://ubuntu-lts
fi
limactl start "$NAME"

cat <<EOF

VM '$NAME' is running. The repo is mounted at the same path inside the VM.
Continue INSIDE the VM (the host is now just a hypervisor):

  limactl shell $NAME
  cd $REPO_ROOT
  HCLOUD_STORAGE_DIR=/var/lib/hcloud/storage bash platform/linux/10-host-prep.sh
  bash hcloud/10-install-k8s.sh && bash hcloud/11-storage.sh && bash hcloud/12-ingress-tls.sh ...

Ports: Lima forwards 127.0.0.1 ports to the VM; public serving does not need any of them
(hcloud/13-public-tunnel.sh runs cloudflared inside the cluster).
Stop/remove: limactl stop $NAME · limactl delete $NAME
EOF
