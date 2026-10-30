#!/usr/bin/env bash
# CPU counters and etcd metrics of every node, taken before and after a step.
#   cpu-stat.jsonl      the first line of /proc/stat on each node
#   etcd-metrics.jsonl  WAL fsync and backend commit histograms, leader changes, failed proposals
#   steal_pct.jsonl     after: the share of CPU time the hypervisor gave to others during the step, per node
# A node that rebooted during the step has counters from its boot: that line says reset.
# Usage: bench/stats.sh <step> before|after
source "$(dirname "$0")/../lib.sh"

step="$1"
phase="$2"
out="$(run_dir)"
families='etcd_disk_wal_fsync_duration_seconds|etcd_disk_backend_commit_duration_seconds|etcd_server_leader_changes_seen_total|etcd_server_proposals_failed_total|etcd_server_is_leader'

sample() {
  local a="$1" zone reply at
  zone="$(field "$a" zone)"
  reply="$(on "$a" "date +%s.%N; head -1 /proc/stat; sed -n 's/^btime //p' /proc/stat; curl -s --max-time 5 http://127.0.0.1:2381/metrics | grep -E '^($families)' || true")"
  at="$(sed -n 1p <<<"$reply")"

  sed -n 2p <<<"$reply" | jq -Rc --arg step "$step" --arg phase "$phase" --arg zone "$zone" \
    --arg node "$(field "$a" name)" --argjson at "$at" --argjson boot "$(sed -n 3p <<<"$reply")" '
    [splits(" +")][1:] | map(tonumber) as $c
    | {step: $step, phase: $phase, zone: $zone, node: $node, at: $at, boot: $boot,
       user: $c[0], nice: $c[1], system: $c[2], idle: $c[3], iowait: $c[4], irq: $c[5], softirq: $c[6], steal: $c[7]}' \
    >>"$out/cpu-stat.jsonl"

  [[ "$(sed -n '4,$p' <<<"$reply")" == etcd_* ]] || return 0
  sed -n '4,$p' <<<"$reply" | jq -Rnc --arg step "$step" --arg phase "$phase" --arg zone "$zone" \
    --arg node "$(field "$a" name)" --argjson at "$at" '
    [inputs | capture("^(?<name>[a-z_]+)(\\{(?<labels>[^}]*)\\})? (?<value>\\S+)$")] as $m
    | def histogram($h): {
        buckets: [$m[] | select(.name == "\($h)_bucket") | {le: (.labels | capture("le=\"(?<v>[^\"]+)\"").v), count: (.value | tonumber)}],
        count: ([$m[] | select(.name == "\($h)_count") | .value | tonumber] | add),
        sum: ([$m[] | select(.name == "\($h)_sum") | .value | tonumber] | add)};
      def value($n): [$m[] | select(.name == $n) | .value | tonumber] | add;
    {step: $step, phase: $phase, zone: $zone, node: $node, at: $at,
     wal_fsync: histogram("etcd_disk_wal_fsync_duration_seconds"),
     backend_commit: histogram("etcd_disk_backend_commit_duration_seconds"),
     leader_changes: value("etcd_server_leader_changes_seen_total"),
     proposals_failed: value("etcd_server_proposals_failed_total"),
     is_leader: value("etcd_server_is_leader")}' >>"$out/etcd-metrics.jsonl"
}

for ((i = 0; i < $(count); i++)); do
  sample "$(node "$i")"
done

[[ "$phase" == after ]] || exit 0
jq -sc --arg step "$step" '
  map(select(.step == $step)) | group_by(.node)[]
  | (map(select(.phase == "before")) | last) as $b | (map(select(.phase == "after")) | last) as $a
  | select($b and $a)
  | def total($s): $s.user + $s.nice + $s.system + $s.idle + $s.iowait + $s.irq + $s.softirq + $s.steal;
    (if $a.boot and $b.boot then $a.boot != $b.boot
     else total($a) < total($b) or any(["user", "system", "idle", "steal"][]; $a[.] < $b[.]) end) as $reset
  | (if $reset then {user: 0, nice: 0, system: 0, idle: 0, iowait: 0, irq: 0, softirq: 0, steal: 0} else $b end) as $from
  | (total($a) - total($from)) as $t
  | {step: $step, zone: $a.zone, node: $a.node, seconds: ($a.at - $b.at), reset: $reset,
     steal_pct: (if $t > 0 then ($a.steal - $from.steal) * 100 / $t else null end),
     busy_pct: (if $t > 0 then ($t - ($a.idle - $from.idle) - ($a.iowait - $from.iowait)) * 100 / $t else null end)}' \
  "$out/cpu-stat.jsonl" | tee -a "$out/steal_pct.jsonl"
