#!/usr/bin/env bash
# Phase 0: install the virtualization stack CRC needs. Requires sudo. Idempotent.
set -euo pipefail

echo "==> Installing libvirt/KVM stack"
sudo apt-get update
sudo apt-get install -y \
  qemu-kvm libvirt-daemon-system libvirt-clients virtiofsd \
  network-manager jq curl xz-utils

echo "==> Enabling libvirt daemon"
sudo systemctl enable --now libvirtd

echo "==> Adding $USER to libvirt group"
sudo usermod -aG libvirt "$USER"

echo "==> Checking KVM"
[ -e /dev/kvm ] && echo "  /dev/kvm present" || { echo "  ERROR: /dev/kvm missing (enable VT-x in BIOS)"; exit 1; }

cat <<'EOF'

Done. Two manual steps remain:
  1. Log out and back in (or run `newgrp libvirt`) so the group change takes effect.
  2. Download your free Red Hat pull secret from
       https://console.redhat.com/openshift/create/local
     and save it as ~/pull-secret.txt
Then run scripts/01-install-crc.sh
EOF
