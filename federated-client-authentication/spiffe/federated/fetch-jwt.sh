#!/usr/bin/env bash
set -euo pipefail
umask 077
HERE=$(cd "$(dirname "$0")" && pwd)
export KUBECONFIG="$HERE/.runtime/kc-spiffe-east.kubeconfig:$HERE/.runtime/kc-spiffe-west.kubeconfig"
domain=${1:?usage: fetch-jwt.sh east|west [subject]}
subject=${2:-$domain}
case "$domain" in east|west) ;; *) echo 'domain must be east or west' >&2; exit 2 ;; esac
trust_domain="$domain.example.test"
cluster="kc-spiffe-$domain"
context="k3d-$cluster"
node="k3d-$cluster-agent-0"
spiffe_id="spiffe://$trust_domain/client/$subject"
server_exec() {
  kubectl --context "$context" -n spire exec spire-server-0 -c spire-server -- /opt/spire/bin/spire-server "$@"
}
parent_id=$(server_exec agent list -output json | python3 -c 'import json,sys; node=sys.argv[1]; agents=json.load(sys.stdin)["agents"]; a=next(a for a in agents if any(s["type"]=="k8s_psat" and s["value"]=="agent_node_name:"+node for s in a["selectors"])); print("spiffe://"+a["id"]["trust_domain"]+a["id"]["path"])' "$node")
entry_id="demo-$domain-$subject"
if ! server_exec entry show -entryID "$entry_id" >/dev/null 2>&1; then
  server_exec entry create -entryID "$entry_id" -parentID "$parent_id" -spiffeID "$spiffe_id" \
    -selector k8s:ns:default -selector "k8s:sa:demo-$domain-client" -selector "k8s:pod-label:app:$domain-client" -jwtSVIDTTL 300 >/dev/null
fi
job="svid-$domain-$subject"
kubectl --context "$context" -n default delete job "$job" --ignore-not-found >/dev/null
kubectl --context "$context" -n default create serviceaccount "demo-$domain-client" --dry-run=client -o yaml | kubectl --context "$context" apply -f - >/dev/null
kubectl --context "$context" apply -f - <<MANIFEST >/dev/null
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: default
spec:
  backoffLimit: 2
  template:
    metadata:
      labels:
        app: $domain-client
    spec:
      nodeName: $node
      serviceAccountName: demo-$domain-client
      restartPolicy: Never
      containers:
        - name: fetch
          image: ghcr.io/spiffe/spire-agent:1.11.0
          imagePullPolicy: IfNotPresent
          command: ["/opt/spire/bin/spire-agent"]
          args: ["api", "fetch", "jwt", "-output", "json", "-audience", "http://localhost:8180/realms/spiffe", "-spiffeID", "$spiffe_id", "-socketPath", "/spiffe-workload-api/spire-agent.sock"]
          volumeMounts:
            - name: workload-api
              mountPath: /spiffe-workload-api
      volumes:
        - name: workload-api
          csi:
            driver: csi.spiffe.io
            readOnly: true
MANIFEST
kubectl --context "$context" -n default wait --for=condition=complete "job/$job" --timeout=90s >/dev/null
pod=$(kubectl --context "$context" -n default get pods -l "job-name=$job" -o json | python3 -c 'import json,sys; pods=json.load(sys.stdin)["items"]; print(next(p["metadata"]["name"] for p in pods if p["status"]["phase"]=="Succeeded"))')
kubectl --context "$context" -n default logs "$pod" > "$HERE/.runtime/$job.json"
python3 -c 'import json,sys; x=json.load(open(sys.argv[1])); print(x[0]["svids"][0]["svid"])' "$HERE/.runtime/$job.json"
