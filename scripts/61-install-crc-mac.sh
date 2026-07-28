#!/usr/bin/env bash
# Phase 6.1 (Mac Studio target): configure and start CRC (OpenShift Local) on
# Apple Silicon with the mac-studio profile.
#
# Profile — mac-studio: 16 vCPU / 96 GiB (98304 MiB) / 500 GiB disk.
# This is the *primary* HCloud production cluster; enables cluster monitoring
# for NERC-style Prometheus/Grafana on day 1.
#
# Requires:
#   - scripts/60-mac-prereqs.sh finished (crc + oc + helm etc. installed).
#   - Pull secret saved at docs/Secretes/pull-secret.txt (or ~/pull-secret.txt).
#
# Overrides via env:  HCLOUD_CPUS, HCLOUD_MEMORY_MIB, HCLOUD_DISK_GIB.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Locate the pull secret
PULL_SECRET_DEFAULT="$REPO_ROOT/docs/Secretes/pull-secret.txt"
PULL_SECRET="${PULL_SECRET:-$PULL_SECRET_DEFAULT}"
[ -f "$PULL_SECRET" ] || PULL_SECRET="$HOME/pull-secret.txt"
[ -f "$PULL_SECRET" ] || {
  echo "ERROR: pull secret missing at $PULL_SECRET_DEFAULT or ~/pull-secret.txt"
  echo "Get it from https://console.redhat.com/openshift/create/local"
  exit 1
}

# Host checks
[ "$(uname)" = "Darwin" ]   || { echo "ERROR: not macOS"; exit 1; }
[ "$(uname -m)" = "arm64" ] || { echo "ERROR: not Apple Silicon (arm64)"; exit 1; }
command -v crc >/dev/null   || { echo "ERROR: crc missing — run scripts/60-mac-prereqs.sh"; exit 1; }

ram_gib=$(sysctl -n hw.memsize | awk '{printf "%d", $1/1073741824}')
[ "$ram_gib" -ge 96 ] || { echo "ERROR: need >=96 GiB RAM; found ${ram_gib}"; exit 1; }

CPUS="${HCLOUD_CPUS:-16}"
MEM="${HCLOUD_MEMORY_MIB:-98304}"   # 96 GiB
# 4 TiB (sparse qcow2 grows on demand). Sized for real NERC workloads: ~8 TB
# of PVCs is realistic on this box; we relocate ~/.crc to /Volumes/HSZ (20 TiB)
# below when available. If /Volumes/HSZ is not present, root is only 1.8 TiB
# and the disk still fits sparse-allocated, but real usage above ~1 TiB will
# fill root — do not skip the relocation on that scenario.
DISK="${HCLOUD_DISK_GIB:-4000}"

# --- Storage relocation: put ~/.crc on the big Thunderbolt volume ---
# CRC stores the cluster qcow2 in ~/.crc. On this Mac root is only 1.8 TiB but
# /Volumes/HSZ is 20 TiB. Symlink before first `crc setup` so the machine dir
# lands on the big disk. Idempotent: skip if already relocated.
HCLOUD_CRC_HOME="${HCLOUD_CRC_HOME:-/Volumes/HSZ/.crc}"
if [ -d /Volumes/HSZ ] && [ ! -L "$HOME/.crc" ]; then
  if [ ! -d "$HOME/.crc" ]; then
    echo "==> Relocating CRC home to ${HCLOUD_CRC_HOME}"
    mkdir -p "$HCLOUD_CRC_HOME"
    ln -s "$HCLOUD_CRC_HOME" "$HOME/.crc"
  elif [ -z "$(ls -A "$HOME/.crc" 2>/dev/null)" ]; then
    echo "==> ~/.crc exists but empty; moving to ${HCLOUD_CRC_HOME}"
    rmdir "$HOME/.crc"
    mkdir -p "$HCLOUD_CRC_HOME"
    ln -s "$HCLOUD_CRC_HOME" "$HOME/.crc"
  else
    echo "  WARNING: ~/.crc already contains data on root disk. Not moving to /Volumes/HSZ."
    echo "  If you have not yet run 'crc setup', stop, rm -rf ~/.crc, and re-run this script."
  fi
elif [ -L "$HOME/.crc" ]; then
  echo "==> ~/.crc already symlinked to $(readlink "$HOME/.crc")"
fi

echo "==> mac-studio profile: ${CPUS} vCPU / $((MEM/1024)) GiB / ${DISK} GiB disk"
crc config set consent-telemetry no
crc config set cpus "$CPUS"
crc config set memory "$MEM"
crc config set disk-size "$DISK"
crc config set pull-secret-file "$PULL_SECRET"
# NERC-parity: cluster monitoring stack (Prometheus/Grafana) enabled from start.
# ~8 GiB extra footprint; well within the 96 GiB budget.
crc config set enable-cluster-monitoring true
# Longer boot timeout for a big cluster.
crc config set kubeadmin-password ""  || true

echo "==> One-time host setup (installs vfkit; may prompt for password)"
# Gotcha found on this Mac (2026-07-26): with ~/.crc symlinked to /Volumes/HSZ,
# launchd cannot exec/log through the external volume (macOS TCC denies
# removable-volume access to launchd-spawned processes) — the
# com.redhat.crc.daemon LaunchAgent exits code 78 and 'crc setup' fails with
# "daemon is not running yet". Fallback: run the daemon from this session.
start_daemon_if_needed () {
  if ! curl --unix-socket "$HOME/.crc/sockets/crc-http.sock" -s -o /dev/null http://crc/api/version 2>/dev/null; then
    echo "  starting crc daemon manually (launchd/TCC fallback)"
    nohup crc daemon --log-level=info > "$HOME/.crc/daemon-manual.log" 2>&1 &
    for i in $(seq 1 30); do
      [ -S "$HOME/.crc/sockets/crc-http.sock" ] && return 0
      sleep 1
    done
  fi
}
crc setup || start_daemon_if_needed

echo "==> Starting HCloud (first start pulls a ~4 GB bundle; 20-40 min)"
# NOTE (macOS): after any reboot the daemon must be running before 'crc start'.
start_daemon_if_needed
crc start

echo
echo "==> Cluster up. Credentials:"
crc console --credentials
cat <<'EOF'

Console : https://console-openshift-console.apps-crc.testing
CLI     : eval $(crc oc-env) && oc get nodes
Next    : scripts/62-cloudflared-tunnel.sh   (public serving)
          scripts/63-cert-manager.sh         (real TLS certs)
          scripts/64-storage-parity.sh       (NERC storage-class alias + MinIO)
          scripts/65-users-quotas.sh         (NERC-style users + quotas)
          scripts/66-nerc-services.sh        (OpenDataHub / Serverless / Pipelines)
          scripts/67-migrate-to-crc.py       (apply your NERC exports to this cluster)
EOF
