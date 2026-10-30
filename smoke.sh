#!/usr/bin/env bash
# The chain in a few minutes with short measurements, on machines destroyed at the end, also on error or Ctrl-C.
# It proves the scripts work on a provider; its numbers are not for publishing.
# Usage: ./smoke.sh hetzner|scaleway|ovh
set -euo pipefail

provider="$1"
ROOT="$(cd "$(dirname "$0")" && pwd)"
source "$ROOT/env.sh"
export FAST=1
cidr="$(curl -4 -s https://ifconfig.me)/32"
tf() { tofu -chdir="$ROOT/infra/$provider" "$@"; }

trap 'tf destroy -auto-approve -var operator_cidr="$cidr"' EXIT
tf init -input=false >/dev/null
tf apply -auto-approve -var operator_cidr="$cidr"
state="${STATE:-$ROOT}"
tf output -json nodes >"$state/nodes.json"
rm -f "$state/.known_hosts"

"$ROOT/bench/net.sh"
"$ROOT/bench/disk.sh"
"$ROOT/01-k3s/install.sh"

first="$(jq -r '.[0].zone' "$state/nodes.json")"
last="$(jq -r '.[-1].zone' "$state/nodes.json")"
"$ROOT/probe/run.sh" "$first" kube -duration 60s &
sleep 15
"$ROOT/faults/fault.sh" partition "$last" 20
wait
