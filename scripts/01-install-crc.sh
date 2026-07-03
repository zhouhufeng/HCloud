#!/usr/bin/env bash
# Phase 1: download OpenShift Local (crc), configure it for this workstation, start the cluster.
# Sized for: i7-6700 (8 threads), 15 GiB RAM host -> 6 vCPU / 10.5 GiB / 60 GiB VM.
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

echo "==> Configuring cluster VM for this machine"
crc config set consent-telemetry no
crc config set cpus 6
crc config set memory 10752        # MiB; leaves ~4.5 GiB for a lightweight desktop
crc config set disk-size 60        # GiB, on / (82 GiB free); see docs for relocating ~/.crc
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
