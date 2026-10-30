#!/usr/bin/env bash
# Article 2: one Postgres per layout, its commit latency, then the primary's node resets while the probe
# writes from another zone, and every acknowledged row is looked for afterwards.
#   single             one instance
#   async              three instances, one per zone, asynchronous copies
#   sync               three instances, one per zone, a commit waits for one copy (topology A)
#   sync-2             two instances in the first two zones, the third zone only votes for Kubernetes (topology B)
#   sync-2-preferred   as sync-2, but with one copy left Postgres keeps writing instead of waiting
# While the primary is broken a second probe reads from the copies (<label>-read).
# FAULT=partition cuts the primary's zone off for 180 s instead. FAULT=none measures the commit only.
# The operator runs as one pod; each replicated layout is broken with it in another zone (<layout>-<fault>)
# and in the primary's zone (<layout>-<fault>-operator-same-zone).
# OPERATOR_HA=1 runs three operator pods, one per zone, and breaks the zone of the lock holder
# (<layout>-<fault>-operator-ha). REPEAT=<n> does it n times (<layout>-<fault>-operator-ha-<i>).
# Usage: 02-cnpg/run.sh [layout...]
source "$(dirname "$0")/../lib.sh"

CNPG_VERSION="${CNPG_VERSION:-1.30.1}"
export KUBECONFIG="$STATE/kubeconfig"
read -ra zones <<<"$(jq -r 'map(.zone) | join(" ")' "$NODES_FILE")"
layouts=("$@")
[[ ${#layouts[@]} -gt 0 ]] || layouts=(single async sync sync-2 sync-2-preferred)
FAULT="${FAULT:-crash}"
probe_seconds=150s
[[ "$FAULT" == partition ]] && probe_seconds=240s
synchronous() { echo "postgresql: {synchronous: {method: any, number: 1, dataDurability: $1}}"; }

kubectl apply --server-side --force-conflicts -f \
  "https://github.com/cloudnative-pg/cloudnative-pg/releases/download/v$CNPG_VERSION/cnpg-$CNPG_VERSION.yaml" >/dev/null
if [[ -n "${OPERATOR_HA:-}" ]]; then
  kubectl -n cnpg-system patch deployment cnpg-controller-manager --type merge -p '{"spec": {"replicas": 3,
    "strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}},
    "template": {"spec": {"nodeSelector": null, "affinity": {"podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
      {"topologyKey": "topology.kubernetes.io/zone", "labelSelector": {"matchLabels": {"app.kubernetes.io/name": "cloudnative-pg"}}}]}}}}}}' >/dev/null
fi
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s >/dev/null
kubectl create namespace ha --dry-run=client -o yaml | kubectl apply -f - >/dev/null

api_up() { until kubectl get --raw /readyz >/dev/null 2>&1; do sleep 2; done; }

create() {
  local name="$1" instances=3 postgresql="" data_zones="${zones[*]}"
  case "$name" in
    single) instances=1 ;;
    sync) postgresql="$(synchronous required)" ;;
    sync-2) instances=2 data_zones="${zones[0]} ${zones[1]}" postgresql="$(synchronous required)" ;;
    sync-2-preferred) instances=2 data_zones="${zones[0]} ${zones[1]}" postgresql="$(synchronous preferred)" ;;
  esac

  kubectl apply -f - >/dev/null <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: $name, namespace: ha}
spec:
  instances: $instances
  storage: {size: 5Gi}
  $postgresql
  affinity:
    enablePodAntiAffinity: true
    podAntiAffinityType: required
    topologyKey: topology.kubernetes.io/zone
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - {key: topology.kubernetes.io/zone, operator: In, values: [${data_zones// /, }]}
EOF
  healthy "$name"
}

healthy() {
  kubectl -n ha wait "cluster/$1" --for=condition=Ready --timeout=900s >/dev/null
  kubectl -n ha wait "cluster/$1" --for=jsonpath='{.status.readyInstances}'="$(kubectl -n ha get cluster "$1" -o jsonpath='{.spec.instances}')" --timeout=900s >/dev/null
}

primary_zone() { pod_zone ha "$(kubectl -n ha get cluster "$1" -o jsonpath='{.status.currentPrimary}')"; }

operator_to() {
  if [[ -n "${OPERATOR_HA:-}" ]]; then
    local try leader
    kubectl -n cnpg-system wait pod -l app.kubernetes.io/name=cloudnative-pg --for=condition=Ready --timeout=600s >/dev/null
    for ((try = 0; try < 10; try++)); do
      leader="$(kubectl -n cnpg-system get lease db9c8771.cnpg.io -o jsonpath='{.spec.holderIdentity}')"
      leader="${leader%%_*}"
      [[ "$(pod_zone cnpg-system "$leader")" == "$1" ]] && return 0
      kubectl -n cnpg-system delete pod "$leader" --wait=false >/dev/null
      sleep 25
    done
    return 1
  fi
  kubectl -n cnpg-system patch deployment cnpg-controller-manager --type merge \
    -p "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"topology.kubernetes.io/zone\":\"$1\"}}}}}" >/dev/null
  kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=300s >/dev/null
}

# Saved before the next move of the operator deletes its pods and their logs.
evidence() {
  local pod
  mkdir -p "$2"
  for pod in $(kubectl -n cnpg-system get pods -o name); do
    kubectl -n cnpg-system logs "$pod" >"$2/${pod#pod/}.log" 2>/dev/null || true
    kubectl -n cnpg-system logs "$pod" --previous >"$2/${pod#pod/}.previous.log" 2>/dev/null || true
  done
  kubectl -n ha get events --sort-by=.lastTimestamp >"$2/events.txt" 2>/dev/null || true
  kubectl -n ha get cluster "$1" -o json >"$2/cluster.json" 2>/dev/null || true
}

# Read from a node outside the lost zone: the API this machine talks to may sit in it.
during() {
  local a remote
  a="$(node_in "$3")"
  remote="$(cat <<'REMOTE'
k() { k3s kubectl "$@"; }
k get pods -A -o wide
k -n ha get cluster NAME -o jsonpath='primary {.status.currentPrimary}{"\n"}'
for pod in $(k -n ha get pods -l cnpg.io/cluster=NAME -o jsonpath='{.items[*].metadata.name}'); do
  node="$(k -n ha get pod "$pod" -o jsonpath='{.spec.nodeName}')"
  if [ "$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" != True ]; then
    echo "$pod on a lost node"
    continue
  fi
  k -n ha exec "$pod" -c postgres -- sh -c 'getent hosts NAME-rw >/dev/null && echo "$0 dns ok" || echo "$0 dns FAILS"
    psql -U postgres -Atc "select pg_is_in_recovery(), (select string_agg(application_name || chr(58) || state || chr(58) || sync_state, chr(32)) from pg_stat_replication), (select status from pg_stat_wal_receiver)"' "$pod"
done
REMOTE
)"
  mkdir -p "$2"
  on "$a" "${remote//NAME/$1}" >"$2/during.txt" 2>&1 || true
}

break_primary() {
  [[ "$FAULT" == none ]] && return 0
  local name="$1" label="$2" operator_zone="$3" primary="$4" writer="$5" dsn="$6" out controllers
  out="$(run_dir)"
  [[ -e "$out/probe-$label.jsonl" ]] && { echo "$label already measured in $out" >&2; return 1; }
  operator_to "$operator_zone"
  LABEL="$label" "$ROOT/probe/run.sh" "$writer" pg -dsn "$dsn" -duration "$probe_seconds" &
  sleep 5
  [[ "$name" != single ]] && LABEL="$label-read" "$ROOT/probe/run.sh" "$writer" read -dsn "$ro_dsn" -duration "$probe_seconds" &
  sleep 15
  controllers="$(kubectl -n kube-system get lease kube-controller-manager -o jsonpath='{.spec.holderIdentity}')"
  "$ROOT/faults/fault.sh" "$FAULT" "$primary" 180 >/dev/null
  (sleep 120 && during "$name" "$out/operator-$label" "$writer") &
  wait
  evidence "$name" "$out/operator-$label"
  ready
  api_up
  healthy "$name" || true
  LABEL="$label-verify" "$ROOT/probe/run.sh" "$writer" verify -dsn "$dsn" -acks /dev/stdin <"$out/probe-$label.jsonl" || true
  jq -nc --arg run "$label" --arg operator "$operator_zone" --arg before "$primary" --arg after "$(primary_zone "$name")" \
    --arg controllers "${controllers%%_*}" \
    '{run: $run, operator_zone: $operator, primary_zone_before: $before, primary_zone_after: $after,
      controller_manager_node: $controllers}' |
    tee -a "$out/cnpg-crashes.jsonl"
}

# Throughput with 1, 8 and 32 clients next to the primary, as an app would be: one commit's wait matters less
# when many clients commit at once.
throughput() {
  local name="$1" zone="$2" password="$3" host="$4" clients result
  kubectl -n ha delete pod pgbench --ignore-not-found --wait=true >/dev/null
  kubectl -n ha run pgbench --image="$(kubectl -n ha get cluster "$name" -o jsonpath='{.status.image}')" \
    --restart=Never --env=PGPASSWORD="$password" \
    --overrides="{\"spec\":{\"nodeName\":\"$(field "$(node_in "$zone")" name)\"}}" --command -- sleep 3600 >/dev/null
  kubectl -n ha wait pod pgbench --for=condition=Ready --timeout=300s >/dev/null
  kubectl -n ha exec pgbench -- pgbench -i -q -s 10 -h "$host" -U app app >/dev/null 2>&1
  for clients in 1 8 32; do
    result="$(kubectl -n ha exec pgbench -- pgbench -n -c "$clients" -j "$clients" -T 30 -h "$host" -U app app 2>/dev/null)"
    jq -nc --arg layout "$name" --arg zone "$zone" --argjson clients "$clients" \
      --argjson tps "$(awk '/^tps/ {print $3}' <<<"$result")" \
      --argjson latency "$(awk '/^latency average/ {print $4}' <<<"$result")" \
      '{layout: $layout, client_zone: $zone, clients: $clients, tps: $tps, latency_ms: $latency}' |
      tee -a "$(run_dir)/cnpg-pgbench.jsonl"
  done
  kubectl -n ha delete pod pgbench --wait=true >/dev/null
}

for name in "${layouts[@]}"; do
  echo "== $name" >&2
  create "$name"

  primary="$(primary_zone "$name")"
  writer="$(other_zone "$primary")"
  password="$(kubectl -n ha get secret "$name-app" -o jsonpath='{.data.password}' | base64 -d)"
  host="$(kubectl -n ha get service "$name-rw" -o jsonpath='{.spec.clusterIP}')"
  dsn="postgres://app:$password@$host:5432/app?connect_timeout=2"
  ro_dsn="postgres://app:$password@$(kubectl -n ha get service "$name-ro" -o jsonpath='{.spec.clusterIP}'):5432/app?connect_timeout=2"
  jq -nc --arg layout "$name" --arg image "$(kubectl -n ha get cluster "$name" -o jsonpath='{.status.image}')" \
    --arg primary "$primary" '{layout: $layout, image: $image, primary_zone: $primary}' >>"$(run_dir)/cnpg-layouts.jsonl"

  if [[ "$FAULT" != partition ]]; then
    LABEL="$name-commit" "$ROOT/probe/run.sh" "$writer" pg -dsn "$dsn" -interval 0s -duration "${PROBE_SECONDS}s"
    LABEL="$name-commit-same-zone" "$ROOT/probe/run.sh" "$primary" pg -dsn "$dsn" -interval 0s -duration "${PROBE_SECONDS}s"
    throughput "$name" "$primary" "$password" "$host" || echo "pgbench failed on $name" >&2
  fi

  if [[ -n "${OPERATOR_HA:-}" ]]; then
    for ((r = 1; r <= ${REPEAT:-1}; r++)); do
      primary="$(primary_zone "$name")"
      writer="$(other_zone "$primary")"
      break_primary "$name" "$name-$FAULT-operator-ha${REPEAT:+-$r}" "$primary" "$primary" "$writer" "$dsn"
    done
  else
    break_primary "$name" "$name-$FAULT" "$writer" "$primary" "$writer" "$dsn"
  fi

  if [[ "$name" != single && -z "${OPERATOR_HA:-}" ]]; then
    primary="$(primary_zone "$name")"
    writer="$(other_zone "$primary")"
    break_primary "$name" "$name-$FAULT-operator-same-zone" "$primary" "$primary" "$writer" "$dsn"
  fi

  kubectl -n ha delete cluster "$name" --wait=true >/dev/null
done
