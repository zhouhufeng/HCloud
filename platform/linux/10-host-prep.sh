#!/usr/bin/env bash
# Platform: any Linux host (bare metal or VM) · 10 — prepare the host for the middleware.
#
# Works for the `pc` box, a Dell MX750c sled, an OpenStack/AWS VM, or a Lima VM.
#   HCLOUD_STORAGE_DIR   directory for PV data (default /var/lib/hcloud/storage). If
#                        HCLOUD_STORAGE_DEV is set (e.g. /dev/nvme1n1), it is formatted
#                        ext4 WHEN EMPTY and mounted there via fstab.
#   HCLOUD_REQUIRE_MOUNT=true   fail unless HCLOUD_STORAGE_DIR is its own mountpoint
# Writes hcloud/hcloud.env from the example if absent. Idempotent. Needs sudo.
set -euo pipefail
. "$(dirname "$0")/../../hcloud/lib.sh"; hc_load_env

hc_log "Host: $(. /etc/os-release && echo "$PRETTY_NAME") · $(nproc) threads · $(awk '/MemTotal/{printf "%d GiB",$2/1048576}' /proc/meminfo)"
[ "$(uname -m)" = x86_64 ] || [ "$(uname -m)" = aarch64 ] || hc_die "unsupported arch $(uname -m)"
grep -qE 'vmx|svm' /proc/cpuinfo || hc_warn "no virtualization flags — fine for K3s, matters only for KubeVirt/CRC"

hc_log "Base packages"
if command -v apt-get >/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq curl jq python3 python3-yaml open-iscsi nfs-common >/dev/null
elif command -v dnf >/dev/null; then
  sudo dnf install -y -q curl jq python3 python3-pyyaml iscsi-initiator-utils nfs-utils
fi

hc_log "Kernel/sysctl for Kubernetes"
sudo tee /etc/sysctl.d/90-hcloud.conf >/dev/null <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches   = 1048576
net.ipv4.ip_forward           = 1
vm.max_map_count              = 262144
EOF
sudo sysctl --system >/dev/null
if swapon --show | grep -q .; then
  hc_log "Disabling swap (kubelet requirement)"; sudo swapoff -a; sudo sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
fi

# A CRC VM from the legacy path holds RAM the cluster needs; make sure it is down.
if command -v crc >/dev/null 2>&1; then crc stop >/dev/null 2>&1 || true; fi
sudo virsh -c qemu:///system destroy crc >/dev/null 2>&1 || true

hc_log "Storage → $HCLOUD_STORAGE_DIR"
if [ -n "${HCLOUD_STORAGE_DEV:-}" ]; then
  [ -b "$HCLOUD_STORAGE_DEV" ] || hc_die "$HCLOUD_STORAGE_DEV is not a block device"
  if ! sudo blkid "$HCLOUD_STORAGE_DEV" >/dev/null 2>&1; then
    hc_log "Formatting empty $HCLOUD_STORAGE_DEV as ext4"; sudo mkfs.ext4 -q -L hcloud-data "$HCLOUD_STORAGE_DEV"
  fi
  sudo mkdir -p "$HCLOUD_STORAGE_DIR"
  UUID="$(sudo blkid -s UUID -o value "$HCLOUD_STORAGE_DEV")"
  grep -q "UUID=$UUID" /etc/fstab || echo "UUID=$UUID $HCLOUD_STORAGE_DIR ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
  mountpoint -q "$HCLOUD_STORAGE_DIR" || sudo mount "$HCLOUD_STORAGE_DIR"
fi
sudo mkdir -p "$HCLOUD_STORAGE_DIR"
if ! mountpoint -q "$HCLOUD_STORAGE_DIR"; then
  msg="$HCLOUD_STORAGE_DIR is not its own mountpoint — PVs will share the root filesystem"
  [ "${HCLOUD_REQUIRE_MOUNT:-false}" = true ] && hc_die "$msg" || hc_warn "$msg"
fi
df -h "$HCLOUD_STORAGE_DIR" | tail -1

if [ ! -f "$HCLOUD_ENV" ]; then
  hc_log "Writing $HCLOUD_ENV from the example"
  sed "s|^HCLOUD_STORAGE_DIR=.*|HCLOUD_STORAGE_DIR=$HCLOUD_STORAGE_DIR|" "$HCLOUD_ROOT/hcloud/hcloud.env.example" > "$HCLOUD_ENV"
  echo "   edit it (HCLOUD_DOMAIN, HCLOUD_USERS, node role) before running the middleware"
fi

echo; echo "Host ready. Next: bash hcloud/10-install-k8s.sh"
