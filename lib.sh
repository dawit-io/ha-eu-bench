# Sourced by every script. Nodes come from `tofu output -json nodes > nodes.json`.
# FAST=1 shortens every measurement: it checks the chain, its numbers are not for publishing.
# STATE=<dir> keeps one cluster's files (nodes.json, kubeconfig, token) apart, to run several providers at once.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE="${STATE:-$ROOT}"
NODES_FILE="${NODES_FILE:-$STATE/nodes.json}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$STATE/.known_hosts" -o LogLevel=ERROR -o ConnectTimeout=5)

# shellcheck disable=SC2034
if [[ -n "${FAST:-}" ]]; then
  PINGS=50 IPERF_SECONDS=5 FIO_SECONDS=15 FIO_SIZE=256M PROBE_SECONDS=20
else
  PINGS=300 IPERF_SECONDS=20 FIO_SECONDS=60 FIO_SIZE=2G PROBE_SECONDS=60
fi

count() { jq length "$NODES_FILE"; }
node() { jq -c ".[$1]" "$NODES_FILE"; }
field() { jq -r ".$2" <<<"$1"; }
node_in() { jq -c --arg z "$1" 'map(select(.zone == $z))[0]' "$NODES_FILE"; }
other_zone() { jq -r --arg z "$1" '[.[].zone | select(. != $z)][0]' "$NODES_FILE"; }

on() {
  ssh "${SSH_OPTS[@]}" "$(field "$1" ssh_user)@$(field "$1" public_ip)" "sudo bash -c $(printf '%q' "$2")"
}

ready() {
  local i a tries
  for ((i = 0; i < $(count); i++)); do
    a="$(node "$i")"
    for ((tries = 0; tries < 60; tries++)); do
      on "$a" "cloud-init status --wait >/dev/null" 2>/dev/null && break
      sleep 5
    done
  done
}

pod_zone() {
  kubectl get node "$(kubectl -n "$1" get pod "$2" -o jsonpath='{.spec.nodeName}')" \
    -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'
}

run_dir() {
  local first dir
  first="$(node 0)"
  dir="${RUN_DIR:-$ROOT/results/$(field "$first" provider)-$(field "$first" type)-$(date -u +%Y%m%d)${FAST:+-fast}}"
  mkdir -p "$dir"
  jq 'map(del(.public_ip))' "$NODES_FILE" >"$dir/nodes.json"
  echo "$dir"
}
