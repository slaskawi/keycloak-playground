#!/usr/bin/env bash
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
for cluster in kc-spiffe-east kc-spiffe-west; do
  if k3d cluster list -o json | python3 -c 'import json,sys; n=sys.argv[1]; print(any(c["name"] == n for c in json.load(sys.stdin)))' "$cluster" | grep -q True; then
    k3d cluster delete "$cluster"
  fi
done
if docker network inspect kc-spiffe-federation >/dev/null 2>&1; then
  docker network rm kc-spiffe-federation
fi
rm -rf "$HERE/.runtime"
