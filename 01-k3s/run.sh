#!/usr/bin/env bash
# Article 1 measurements. The probe writes to the API of the first zone's server, which is never broken.
#   latency              write latency with the etcd leader in each zone (latency-leader-<zone>)
#   partition-follower   a zone without the leader reaches nobody for 30 s
#   partition-leader     the leader's zone reaches nobody for 30 s
#   crash-leader         the leader's node resets
# REPEAT=<n> runs each fault n times (<fault>-<i>). Every step saves CPU counters and etcd metrics before and after.
# Usage: 01-k3s/run.sh [step...]
source "$(dirname "$0")/../lib.sh"

here="$(dirname "$0")"
writer="$(field "$(node 0)" zone)"
read -ra zones <<<"$(jq -r 'map(.zone) | join(" ")' "$NODES_FILE")"
steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(latency partition-follower partition-leader crash-leader)

probe() { LABEL="$1" "$ROOT/probe/run.sh" "$writer" kube -duration "$2"; }

fault() {
  local label="$1" action="$2" target="$3"
  "$here/healthy.sh" >/dev/null
  "$here/leader.sh" "${zones[2]}" >/dev/null
  "$ROOT/bench/stats.sh" "$label" before >/dev/null
  probe "$label" 90s &
  sleep 20
  "$ROOT/faults/fault.sh" "$action" "$target" 30 >/dev/null
  wait
  ready
  "$here/healthy.sh" >/dev/null || true
  "$ROOT/bench/stats.sh" "$label" after >/dev/null
}

for step in "${steps[@]}"; do
  for ((r = 1; r <= ${REPEAT:-1}; r++)); do
    label="$step${REPEAT:+-$r}"
    case "$step" in
      latency)
        ((r == 1)) || continue
        "$ROOT/bench/stats.sh" "$step" before >/dev/null
        for zone in "${zones[@]}"; do
          "$here/leader.sh" "$zone" >/dev/null
          probe "latency-leader-$zone" "${PROBE_SECONDS}s"
        done
        "$ROOT/bench/stats.sh" "$step" after >/dev/null
        ;;
      partition-follower) fault "$label" partition "${zones[1]}" ;;
      partition-leader) fault "$label" partition "${zones[2]}" ;;
      crash-leader) fault "$label" crash "${zones[2]}" ;;
    esac
  done
done
