#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
KC_DIST=${KC_DIST:-"$HERE/../../../../keycloak/quarkus/dist/target/keycloak-999.0.0-SNAPSHOT.tar.gz"}
KC_HOME="$HERE/.runtime/keycloak-999.0.0-SNAPSHOT"
if [ ! -x "$KC_HOME/bin/kc.sh" ]; then
  mkdir -p "$HERE/.runtime"
  tar -xzf "$KC_DIST" -C "$HERE/.runtime"
fi
exec "$KC_HOME/bin/kc.sh" start-dev --db=dev-mem --features=client-auth-federated,spiffe --bootstrap-admin-username=admin --bootstrap-admin-password=admin --http-port=8180 --truststore-paths="$HERE/.runtime/demo-map.crt"
