#!/usr/bin/env bash
# Everything measured, one JSON document per results folder, in one array: network, disk, probe runs,
# verifications, CNPG fault records, replicated volumes, the app under zone loss, CPU steal and etcd's own
# timings. Input for charts, tables and writing.
# Usage: bench/export.sh results/<run> [results/<run>...] > export.json
set -euo pipefail

here="$(dirname "$0")"
slurp() { [[ -s "$run/$1" ]] && jq -s . "$run/$1" || echo '[]'; }

for run in "$@"; do
  verify="$(for f in "$run"/probe-*-verify.jsonl; do
    [[ -e "$f" ]] || continue
    name="$(basename "$f" -verify.jsonl | sed 's/^probe-//')"
    if [[ -s "$f" ]]; then
      jq -c --arg run "$name" '{run: $run, rows, acknowledged_and_lost: (.acknowledged_and_lost | length)}' "$f"
    else
      jq -nc --arg run "$name" '{run: $run, verified: false}'
    fi
  done | jq -s .)"
  jq -n --arg folder "$(basename "$run")" \
    --argjson nodes "$(jq 'map(del(.public_ip))' "$run/nodes.json")" \
    --argjson net "$(slurp net.jsonl)" --argjson disk "$(slurp disk.jsonl)" \
    --argjson probes "$("$here/summary.sh" "$run" | jq -s .)" --argjson verify "$verify" \
    --argjson cnpg_faults "$(slurp cnpg-crashes.jsonl)" --argjson faults "$(slurp faults.jsonl)" \
    --argjson volumes_disk "$(slurp volumes-disk.jsonl)" --argjson volumes_failover "$(slurp volumes-failover.jsonl)" \
    --argjson volumes_postgres "$(slurp volumes-postgres.jsonl)" \
    --argjson app_partitions "$(slurp app-partitions.jsonl)" --argjson steal "$(slurp steal_pct.jsonl)" \
    --argjson etcd "$(if [[ -s "$run/etcd-metrics.jsonl" ]]; then "$here/etcd.sh" "$run" | jq -s .; else echo '[]'; fi)" \
    '{folder: $folder, nodes: $nodes, net: $net, disk: $disk, probes: $probes, verify: $verify,
      cnpg_faults: $cnpg_faults, faults: $faults, volumes_disk: $volumes_disk,
      volumes_failover: $volumes_failover, volumes_postgres: $volumes_postgres,
      app_partitions: $app_partitions, steal: $steal, etcd: $etcd}'
done | jq -s .
