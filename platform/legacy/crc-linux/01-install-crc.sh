#!/usr/bin/env bash
# Phase 1: download OpenShift Local (crc), configure it for this machine, start the cluster.
# Auto-sizes the cluster VM from host RAM:
#   home profile   (<24 GB host, e.g. 15 GiB desktop) -> 6 vCPU / 10.5 GiB /  60 GiB disk
#   office profile (>=24 GB host, e.g. 32 GB machine) -> 6 vCPU / 18 GiB   / 120 GiB disk
# Override with env vars: HCLOUD_CPUS, HCLOUD_MEMORY_MIB, HCLOUD_DISK_GIB.
set -euo pipefail

CRC_URL="https://mirror.openshift.com/pub/openshift-v4/clients/crc/latest/crc-linux-amd64.tar.xz"
PULL_SECRET="${PULL_SECRET:-$HOME/pull-secret.txt}"

if ! command -v crc >/dev/null; then
  echo "==> Downloading crc from the OpenShift mirror (~3 GB with bundle later; binary ~100 MB)"
  tmp=$(mktemp -d)
  curl -L --fail -o "$tmp/crc.tar.xz" "$CRC_URL"
  tar -xJf "$tmp/crc.tar.xz" -C "$tmp"
  mkdir -p "$HOME/.local/bin"
  install "$tmp"/crc-linux-*/crc "$HOME/.local/bin/crc"
  rm -rf "$tmp"
  echo "  installed to ~/.local/bin/crc (ensure ~/.local/bin is on PATH)"
fi
crc version

if [ ! -f "$PULL_SECRET" ]; then
  echo "ERROR: pull secret not found at $PULL_SECRET"
  echo "Get it from https://console.redhat.com/openshift/create/local (free developer account)."
  exit 1
fi

host_ram_gib=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
if [ "$host_ram_gib" -ge 24 ]; then
  profile=office; mem=18432; disk=120
else
  profile=home; mem=10752; disk=60
fi
CPUS="${HCLOUD_CPUS:-6}"
MEM="${HCLOUD_MEMORY_MIB:-$mem}"
DISK="${HCLOUD_DISK_GIB:-$disk}"

echo "==> Host has ${host_ram_gib} GiB RAM -> '$profile' profile: ${CPUS} vCPU, ${MEM} MiB RAM, ${DISK} GiB disk"
crc config set consent-telemetry no
crc config set cpus "$CPUS"
crc config set memory "$MEM"
crc config set disk-size "$DISK"
crc config set pull-secret-file "$PULL_SECRET"

echo "==> One-time host setup"
crc setup

echo "==> Starting HCloud (first start downloads a ~4 GB bundle and takes 20-40 min)"
crc start

echo "==> Cluster up. Credentials:"
crc console --credentials
echo
echo "Console: https://console-openshift-console.apps-crc.testing"
echo "CLI:     eval \$(crc oc-env) && oc get nodes"
