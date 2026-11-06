#!/usr/bin/env bash
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
KC_HOME="$HERE/.runtime/keycloak-999.0.0-SNAPSHOT"
KCADM="$KC_HOME/bin/kcadm.sh"
KCADM_CONFIG="$HERE/.runtime/kcadm.config"
"$KCADM" config credentials --config "$KCADM_CONFIG" --server http://localhost:8180 --realm master --user admin --password admin
"$KCADM" create realms --config "$KCADM_CONFIG" -s realm=spiffe -s enabled=true
for domain in east west; do
  trust_domain="$domain.example.test"
  "$KCADM" create identity-provider/instances --config "$KCADM_CONFIG" -r spiffe \
    -s "alias=$domain" -s providerId=spiffe \
    -s "config={\"trustDomain\":\"spiffe://$trust_domain\",\"bundleEndpoint\":\"https://localhost:9443/bundle\"}"
  "$KCADM" create clients --config "$KCADM_CONFIG" -r spiffe \
    -s "clientId=$domain-client" -s serviceAccountsEnabled=true \
    -s clientAuthenticatorType=federated-jwt \
    -s "attributes={\"jwt.credential.issuer\":\"$domain\",\"jwt.credential.sub\":\"spiffe://$trust_domain/client/$domain\"}"
done
