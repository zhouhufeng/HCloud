#!/usr/bin/env bash
# Phase 6.9 (Mac Studio target): after data migration, restore original replica counts.
# Reads docs/Secretes/migration/<ns>/crc/_replicas.json (written by 67-migrate-to-crc.py).
set -euo pipefail

NS="${1:-favor-4ee4be}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAP="$REPO_ROOT/docs/Secretes/migration/$NS/crc/_replicas.json"
[ -f "$MAP" ] || { echo "ERROR: $MAP not found. Did you run 67-migrate-to-crc.py?"; exit 1; }
if [ -z "${KUBECONFIG:-}" ] && command -v crc >/dev/null; then eval "$(crc oc-env)"; fi

python3 - "$MAP" "$NS" <<'PY'
import json, subprocess, sys
mp, ns = sys.argv[1], sys.argv[2]
for k, r in json.load(open(mp)).items():
    kind, name = k.split("/", 1)
    if int(r) <= 0: continue
    print(f"==> scaling {kind}/{name} in {ns} -> {r}")
    subprocess.run(["oc","-n",ns,"scale",f"{kind}/{name}","--replicas",str(r)], check=False)
PY

echo "Done. Watch: oc -n $NS get pods -w"
