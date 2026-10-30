#!/usr/bin/env bash
# Article 1: a stateless app with three replicas, one per zone, behind a Service, while one zone is lost for
# 420 s, longer than the 300 s Kubernetes waits before it evicts the pods of an unreachable node.
# Kubernetes keeps its defaults. The probe sends GET requests to the Service from another zone, whose server
# records every 2 s the nodes, the Service endpoints, the pods, metrics-server and Traefik (app-partition-<i>/kube.jsonl)
# and the health of every etcd member (app-partition-<i>/etcd.jsonl); when K3s stopped and started on the lost
# server comes from its journal (k3s-journal.txt). 01-k3s/app-report.sh turns them into
# app-partition-<i>-timeline.jsonl and one line of app-partitions.jsonl.
# Repetition <i> breaks the next zone in turn. The API this machine talks to may sit in it, so everything
# during the fault goes through the other zone's server.
# Usage: REPEAT=3 01-k3s/app.sh
source "$(dirname "$0")/../lib.sh"

APP_IMAGE="${APP_IMAGE:-traefik/whoami:v1.10.3}"
seconds="${APP_PARTITION_SECONDS:-420}"
export KUBECONFIG="$STATE/kubeconfig"
here="$(dirname "$0")"
read -ra zones <<<"$(jq -r 'map(.zone) | join(" ")' "$NODES_FILE")"
out="$(run_dir)"

kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: app}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: whoami, namespace: app}
spec:
  replicas: 3
  selector: {matchLabels: {app: whoami}}
  template:
    metadata: {labels: {app: whoami}}
    spec:
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: topology.kubernetes.io/zone
          whenUnsatisfiable: DoNotSchedule
          labelSelector: {matchLabels: {app: whoami}}
          matchLabelKeys: [pod-template-hash]
      containers:
        - name: whoami
          image: $APP_IMAGE
          ports: [{containerPort: 80}]
---
apiVersion: v1
kind: Service
metadata: {name: whoami, namespace: app}
spec:
  selector: {app: whoami}
  ports: [{port: 80, targetPort: 80}]
EOF
kubectl -n app rollout status deployment/whoami --timeout=300s >/dev/null

spread() {
  local tries
  for ((tries = 0; tries < 150; tries++)); do
    [[ "$(kubectl -n app get pods -l app=whoami -o json | jq -r '[.items[] | select(.metadata.deletionTimestamp == null)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .spec.nodeName] | unique | length')" == 3 ]] && return 0
    sleep 4
  done
  return 1
}

# Both loops run on the watching server until /run/ha-watch-stop appears, one sample every 2 s.
# shellcheck disable=SC2016
pace='left=$(( 2000 - ($(date +%s%N) - start) / 1000000 )); [ $left -gt 0 ] && sleep "$((left / 1000)).$(printf %03d $((left % 1000)))"'

watch_kube="$(cat <<'REMOTE'
k() { k3s kubectl --request-timeout=2s "$@"; }
traefik="$(k -n kube-system get service traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
tmp="$(mktemp -d)"
while [ ! -e /run/ha-watch-stop ]; do
  start=$(date +%s%N)
  at=$(date +%s.%N)
  k get nodes -o json 2>/dev/null | jq -c '[.items[] | {name: .metadata.name, zone: .metadata.labels["topology.kubernetes.io/zone"],
    ready: ([.status.conditions[] | select(.type == "Ready") | {status, since: .lastTransitionTime}][0]),
    taints: [.spec.taints[]? | "\(.key):\(.effect)"]}]' >"$tmp/nodes" &
  k -n app get endpointslices -l kubernetes.io/service-name=whoami -o json 2>/dev/null | jq -c '[.items[].endpoints[]? |
    {pod: .targetRef.name, node: .nodeName, zone, ready: .conditions.ready, serving: .conditions.serving,
     terminating: .conditions.terminating}]' >"$tmp/endpoints" &
  k get pods -A -o json 2>/dev/null | jq -c '[.items[] | select(.metadata.namespace == "app" or .metadata.namespace == "kube-system") |
    {ns: .metadata.namespace, name: .metadata.name, node: .spec.nodeName, phase: .status.phase,
     ready: ([.status.conditions[]? | select(.type == "Ready") | .status][0]),
     created: .metadata.creationTimestamp, deleting: .metadata.deletionTimestamp}]' >"$tmp/pods" &
  (k top nodes --no-headers >/dev/null 2>&1 && echo true || echo false) >"$tmp/top" &
  (curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://$traefik/" || true) >"$tmp/traefik" &
  wait
  printf '{"at":%s,"nodes":%s,"endpoints":%s,"pods":%s,"metrics_server":%s,"traefik":"%s"}\n' "$at" \
    "$(cat "$tmp/nodes")" "$(cat "$tmp/endpoints")" "$(cat "$tmp/pods")" "$(cat "$tmp/top")" "$(cat "$tmp/traefik")" |
    sed 's/:,/:null,/g'
  PACE
done
rm -rf "$tmp"
REMOTE
)"

watch_etcd="$(cat <<'REMOTE'
while [ ! -e /run/ha-watch-stop ]; do
  start=$(date +%s%N)
  at=$(date +%s.%N)
  health="$(etcdctl --cacert=TLS/server-ca.crt --cert=TLS/client.crt --key=TLS/client.key --endpoints=ENDPOINTS \
    --command-timeout=1500ms endpoint health -w json 2>/dev/null | jq -c 'map({endpoint, health})')"
  printf '{"at":%s,"etcd":%s}\n' "$at" "${health:-null}"
  PACE
done
REMOTE
)"
watch_kube="${watch_kube//PACE/$pace}"
watch_etcd="${watch_etcd//PACE/$pace}"
watch_etcd="${watch_etcd//TLS//var/lib/rancher/k3s/server/tls/etcd}"
watch_etcd="${watch_etcd//ENDPOINTS/$(jq -r 'map("https://\(.private_ip):2379") | join(",")' "$NODES_FILE")}"

recovered() {
  tail -1 "$1/kube.jsonl" | jq -e --arg node "$2" '
    (.nodes | map({key: .name, value: .zone}) | from_entries) as $zone
    | any(.nodes[]; .name == $node and .ready.status == "True")
    and ([.pods[] | select(.ns == "app" and .deleting == null and .ready == "True") | $zone[.node]] | unique | length) == 3' >/dev/null &&
    tail -1 "$1/etcd.jsonl" | jq -e '.etcd != null and all(.etcd[]; .health)' >/dev/null
}

for ((r = 1; r <= ${REPEAT:-1}; r++)); do
  label="app-partition-$r"
  [[ -e "$out/probe-$label.jsonl" ]] && { echo "$label already measured in $out" >&2; exit 1; }
  broken="${zones[$(((r - 1) % ${#zones[@]}))]}"
  watcher="$(other_zone "$broken")"
  w="$(node_in "$watcher")"
  dir="$out/$label"
  mkdir -p "$dir"
  echo "== $label: $broken lost, watched from $watcher" >&2

  "$here/healthy.sh" "$watcher" >/dev/null
  spread
  leader="$("$here/leader.sh")"
  ip="$(kubectl -n app get service whoami -o jsonpath='{.spec.clusterIP}')"
  pod="$(kubectl -n app get pods -l app=whoami -o json | jq -r --arg node "$(field "$(node_in "$broken")" name)" \
    '.items[] | select(.spec.nodeName == $node) | .metadata.name')"
  "$ROOT/bench/stats.sh" "$label" before >/dev/null

  on "$w" "rm -f /run/ha-watch-stop"
  on "$w" "$watch_kube" >"$dir/kube.jsonl" &
  kube_pid=$!
  on "$w" "$watch_etcd" >"$dir/etcd.jsonl" &
  etcd_pid=$!
  LABEL="$label" "$ROOT/probe/run.sh" "$watcher" http -url "http://$ip/" -duration "$((seconds + 140))s" &
  probe_pid=$!

  sleep 20
  partition_at="$("$ROOT/faults/fault.sh" partition "$broken" "$seconds" | jq -s 'map(.at) | min')"
  sleep "$seconds"
  heal_at="$("$ROOT/faults/fault.sh" heal "$broken" | jq -s 'map(.at) | min')"

  for ((tries = 0; tries < 300; tries++)); do
    recovered "$dir" "$(field "$(node_in "$broken")" name)" && break
    sleep 2
  done
  sleep 6
  on "$w" "touch /run/ha-watch-stop"
  wait "$kube_pid" "$etcd_pid" "$probe_pid" || true

  on "$(node_in "$broken")" "journalctl -u k3s --since @${partition_at%.*} -o short-unix --no-pager |
    grep -E 'k3s.service: Main process exited|Started k3s.service'" >"$dir/k3s-journal.txt" 2>/dev/null || true
  kubectl -n app get events -o json >"$dir/events.json" 2>/dev/null || true
  kubectl get pods -A -o wide >"$dir/pods-after.txt" 2>/dev/null || true
  jq -n --arg zone "$broken" --arg node "$(field "$(node_in "$broken")" name)" --arg watcher "$watcher" \
    --arg pod "$pod" --arg leader "$leader" --argjson partition "$partition_at" --argjson heal "$heal_at" \
    --argjson seconds "$seconds" '{zone: $zone, node: $node, watcher: $watcher, pod: $pod, etcd_leader_zone: $leader,
      partition_at: $partition, heal_at: $heal, partition_seconds: $seconds}' >"$dir/meta.json"

  "$here/healthy.sh" "$watcher" >/dev/null || true
  "$ROOT/bench/stats.sh" "$label" after >/dev/null
  "$here/app-report.sh" "$out" "$label" || echo "report of $label failed" >&2
done
