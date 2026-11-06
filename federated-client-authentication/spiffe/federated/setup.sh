#!/usr/bin/env bash
set -euo pipefail
umask 077

HERE=$(cd "$(dirname "$0")" && pwd)
NETWORK=kc-spiffe-federation
EAST=kc-spiffe-east
WEST=kc-spiffe-west
SPIRE_CHART=https://github.com/spiffe/helm-charts-hardened/releases/download/spire-0.24.0/spire-0.24.0.tgz
CRDS_CHART=https://github.com/spiffe/helm-charts-hardened/releases/download/spire-crds-0.5.0/spire-crds-0.5.0.tgz
mkdir -p "$HERE/.runtime"

for cluster in "$EAST" "$WEST"; do
  if k3d cluster list -o json | python3 -c 'import json,sys; n=sys.argv[1]; raise SystemExit(0 if any(c["name"] == n for c in json.load(sys.stdin)) else 1)' "$cluster"; then
    echo "Refusing to reuse existing cluster: $cluster" >&2
    exit 1
  fi
done

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
  echo "Refusing to reuse existing Docker network: $NETWORK" >&2
  exit 1
fi
docker network create "$NETWORK" >/dev/null
k3d cluster create "$EAST" --servers 1 --agents 1 --network "$NETWORK" --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait
k3d cluster create "$WEST" --servers 1 --agents 1 --network "$NETWORK" --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait
k3d kubeconfig merge "$EAST" --output "$HERE/.runtime/$EAST.kubeconfig" --overwrite --kubeconfig-switch-context=false
k3d kubeconfig merge "$WEST" --output "$HERE/.runtime/$WEST.kubeconfig" --overwrite --kubeconfig-switch-context=false
export KUBECONFIG="$HERE/.runtime/$EAST.kubeconfig:$HERE/.runtime/$WEST.kubeconfig"

for cluster in "$EAST" "$WEST"; do
  context="k3d-$cluster"
  helm upgrade --install spire-crds "$CRDS_CHART" --kube-context "$context" --wait
  domain=${cluster#kc-spiffe-}.example.test
  helm upgrade --install spire "$SPIRE_CHART" --kube-context "$context" --namespace spire --create-namespace --wait \
    --set global.spire.trustDomain="$domain" \
    --set global.spire.clusterName="${cluster#kc-spiffe-}" \
    --set global.spire.recommendations.enabled=false \
    --set spire-server.federation.enabled=true \
    --set spire-server.federation.tls.spire.enabled=true \
    --set spire-server.service.type=NodePort
  kubectl --context "$context" -n spire patch service spire-server --type=json \
    -p='[{"op":"add","path":"/spec/ports/1/nodePort","value":30443}]'
done

node_ip() {
  docker inspect --format "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "k3d-$1-server-0"
}
east_url="https://$(node_ip "$EAST"):30443"
west_url="https://$(node_ip "$WEST"):30443"
east_bundle=$(kubectl --context "k3d-$EAST" -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show -format spiffe)
west_bundle=$(kubectl --context "k3d-$WEST" -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server bundle show -format spiffe)

apply_peer() {
  context=$1
  name=$2
  domain=$3
  endpoint=$4
  endpoint_id=$5
  bundle=$6
  printf '%s\n' "$bundle" | sed 's/^/    /' > "$HERE/.runtime/bootstrap-bundle"
  {
    cat <<MANIFEST
apiVersion: spire.spiffe.io/v1alpha1
kind: ClusterFederatedTrustDomain
metadata:
  name: demo-$name
spec:
  className: spire-spire
  trustDomain: $domain
  bundleEndpointURL: $endpoint
  bundleEndpointProfile:
    type: https_spiffe
    endpointSPIFFEID: $endpoint_id
  trustDomainBundle: |
MANIFEST
    cat "$HERE/.runtime/bootstrap-bundle"
  } | kubectl --context "k3d-$context" apply -f -
  rm -f "$HERE/.runtime/bootstrap-bundle"
}

apply_peer "$EAST" west west.example.test "$west_url" spiffe://west.example.test/spire/server "$west_bundle"
apply_peer "$WEST" east east.example.test "$east_url" spiffe://east.example.test/spire/server "$east_bundle"

for cluster in "$EAST" "$WEST"; do
  kubectl --context "k3d-$cluster" -n spire rollout status statefulset/spire-server --timeout=5m
done

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout "$HERE/.runtime/demo-map.key" -out "$HERE/.runtime/demo-map.crt" -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' >/dev/null 2>&1
printf 'Federation is up. Run ./start-demo.sh, then ./configure-keycloak.sh.\n'
