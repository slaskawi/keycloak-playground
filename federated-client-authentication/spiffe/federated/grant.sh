#!/usr/bin/env bash
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
domain=${1:?usage: grant.sh east|west [subject]}
subject=${2:-$domain}
client="$domain-client"
mkdir -p "$HERE/.runtime"
assertion=$(mktemp "$HERE/.runtime/assertion.XXXXXX")
trap 'rm -f "$assertion"' EXIT
"$HERE/fetch-jwt.sh" "$domain" "$subject" | tr -d '\r\n' > "$assertion"
curl --silent --show-error --fail-with-body -X POST \
  -d grant_type=client_credentials \
  -d client_id="$client" \
  -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-spiffe \
  --data-urlencode "client_assertion@$assertion" \
  http://localhost:8180/realms/spiffe/protocol/openid-connect/token
