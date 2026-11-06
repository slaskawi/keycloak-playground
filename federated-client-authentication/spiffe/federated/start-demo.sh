#!/usr/bin/env bash
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG="$HERE/.runtime/kc-spiffe-east.kubeconfig:$HERE/.runtime/kc-spiffe-west.kubeconfig"

python3 "$HERE/publisher.py" --context k3d-kc-spiffe-east --cert "$HERE/.runtime/demo-map.crt" --key "$HERE/.runtime/demo-map.key" --port 9443 > "$HERE/.runtime/publisher.log" 2>&1 &
publisher_pid=$!
cleanup() {
  kill "$publisher_pid" 2>/dev/null || true
  wait "$publisher_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

ready=false
for _ in $(seq 1 30); do
  if curl --silent --fail --cacert "$HERE/.runtime/demo-map.crt" https://localhost:9443/bundle >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [ "$ready" != true ]; then
  cat "$HERE/.runtime/publisher.log" >&2
  exit 1
fi
"$HERE/start-keycloak.sh"
