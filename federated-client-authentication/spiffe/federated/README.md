# Federated SPIRE + Keycloak demo

This demo runs SPIRE in two isolated k3d clusters, then authenticates Keycloak clients from both trust domains. The [SPIFFE Federation specification](https://spiffe.io/docs/latest/spiffe-specs/spiffe_federation/) defines bundle exchange between trust domains; [SPIRE's federation architecture](https://spiffe.io/docs/latest/architecture/federation/readme/) describes the implementation used here. The [simple demo](../simple/README.md) runs a single SPIRE server and agent.

## Topology and trust

`east` and `west` are separate k3d clusters, with independent SPIRE servers and trust domains (`east.example.test` and `west.example.test`). SPIRE federation uses the `https_spiffe` profile. Its initial trust bundles are exchanged during setup; after that SPIRE polls authenticated peer bundle endpoints and updates its local federated bundle store.

The local Keycloak bridge is a separate integration component. It reads only east SPIRE's local bundle API, publishes its current known bundles as a SPIFFE Bundle Map over HTTPS, and never fetches from a foreign endpoint. Its TLS certificate is generated for this demo and its CA is explicitly trusted by Keycloak. SPIRE federation remains the source of remote bundles.

The trust boundary is the local SPIRE server API socket plus the bridge's HTTPS certificate. Do not expose the bridge or demo credentials outside this local test environment.

## Prerequisites

macOS or Linux with Docker, k3d, kubectl, Helm, Python 3, OpenSSL, and the local Keycloak distribution. Docker access is required. The setup creates only `kc-spiffe-east`, `kc-spiffe-west`, and the dedicated `kc-spiffe-federation` Docker network; it refuses to run if either named cluster or the named network already exists.

## Run

From this directory:

```sh
./setup.sh
```

Setup creates both clusters, installs the SPIFFE Helm charts, bootstraps mutual federation, and creates a local bridge certificate. It does not alter the default kubeconfig context.

Start Keycloak and keep this command running in one terminal:

```sh
./start-demo.sh
```

In another terminal, configure the realm and clients:

```sh
./configure-keycloak.sh
```

The bridge runs as a child of `start-demo.sh` and stops when Keycloak exits. It polls east SPIRE's local bundle state every two seconds, atomically replaces the map, and serves it over TLS trusted by Keycloak.

## Verify

Run both positive grants and inspect the JSON responses:

```sh
./grant.sh east
./grant.sh west
```

The local publisher mapping behavior can be checked without clusters:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s . -p 'publisher_test.py'
```

For domain isolation, an east SVID mapped to the west IdP and a real but unmapped east subject must each return HTTP 401. Restore the east client's issuer after the wrong-domain check.

For the commands below, run them from this directory after setup. These helpers address the SPIRE servers inside their own clusters; no host SPIRE CLI is needed:

```sh
export KUBECONFIG="$PWD/.runtime/kc-spiffe-east.kubeconfig:$PWD/.runtime/kc-spiffe-west.kubeconfig"
spire_east() { kubectl --context k3d-kc-spiffe-east -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
spire_west() { kubectl --context k3d-kc-spiffe-west -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"; }
```

To rotate west's JWT authority, prepare the next key:

```sh
spire_west localauthority jwt prepare -output json > .runtime/west-prepared.json
new_kid=$(python3 -c 'import json; print(json.load(open(".runtime/west-prepared.json"))["prepared_authority"]["authority_id"])')
```

Wait for SPIRE's authenticated federation poll to deliver the key to east, then wait for the local bridge to publish it:

```sh
until spire_east bundle list -id spiffe://west.example.test -format spiffe | python3 -c 'import json,sys; kid=sys.argv[1]; raise SystemExit(0 if any(k.get("kid")==kid for k in json.load(sys.stdin)["keys"]) else 1)' "$new_kid"; do sleep 2; done
until curl --silent --fail --cacert .runtime/demo-map.crt https://localhost:9443/bundle | python3 -c 'import json,sys; kid=sys.argv[1]; b=json.load(sys.stdin)["trust_domains"].get("west.example.test",{}); raise SystemExit(0 if any(k.get("kid")==kid for k in b.get("keys",[])) else 1)' "$new_kid"; do sleep 2; done
spire_west localauthority jwt activate -authorityID "$new_kid"
./grant.sh west
```

The fresh grant must succeed without a Keycloak restart or a manual map update.

To withdraw west, remove the relationship from east and dissociate its cached bundle:

```sh
kubectl --context k3d-kc-spiffe-east delete clusterfederatedtrustdomain demo-west
spire_east bundle delete -id spiffe://west.example.test -mode dissociate
until curl --silent --fail --cacert .runtime/demo-map.crt https://localhost:9443/bundle | python3 -c 'import json,sys; raise SystemExit(1 if "west.example.test" in json.load(sys.stdin)["trust_domains"] else 0)'; do sleep 2; done
```

The operator removes the federation relationship when its resource is deleted; SPIRE retains the foreign bundle until the explicit dissociate command. The publisher drops west from the map on its next poll. Wait at least five minutes for Keycloak's bundle cache to expire, then run `./grant.sh west` with a fresh SVID; it must fail. `./grant.sh east` must still succeed. Do not clear Keycloak caches, change the IdP, or restart Keycloak during this check.

## Verified run

The demo produced HTTP 200 for east and west grants, including a west grant using the rotated JWT key. Wrong-domain mapping and an unmapped subject returned HTTP 401. After federation and bundle withdrawal, the bridge map contained only east; after the normal five-minute cache expiry, a fresh west assertion returned HTTP 401 and east returned HTTP 200. The delivered launcher was restarted and smoke-tested with a fresh realm. The full cluster setup was not rerun after final packaging.

## Cleanup

```sh
./cleanup.sh
```

Stop the foreground `./start-demo.sh` process first (Ctrl-C). Cleanup deletes only the two named demo clusters, the dedicated Docker network, and this demo's generated runtime files.
