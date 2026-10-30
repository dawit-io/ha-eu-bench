#!/usr/bin/env bash
# From what 01-k3s/app.sh recorded: one line per change in <label>-timeline.jsonl, and the times that matter
# in app-partitions.jsonl, in seconds from the partition (_s) or from the heal (_after_heal_s).
# Observed times come from the 2 s samples, so one taken while the partition started may show a few hundredths
# of a second below zero; k8s_not_ready_s is the node's own lastTransitionTime, to the second.
# Samples the watching server's API could not answer are left out (watcher_api_gaps counts them).
# Usage: 01-k3s/app-report.sh results/<run> app-partition-<i>
set -euo pipefail

out="$1"
label="$2"
dir="$out/$label"

jq -c --slurpfile meta "$dir/meta.json" '
  $meta[0] as $m
  | select((.nodes | length) > 0 and any(.pods[]?; .ns == "app"))
  | (.nodes // [] | map({key: .name, value: .zone}) | from_entries) as $zone
  | [.pods // [] | .[] | select(.ns == "app")] as $app
  | {at,
     node_ready: ([.nodes[] | select(.name == $m.node) | .ready.status][0]),
     node_since: ([.nodes // [] | .[] | select(.name == $m.node) | .ready.since][0]),
     endpoint: (if .endpoints == null then "no answer" else
       ([.endpoints[] | select(.pod == $m.pod) | if .ready then "ready" elif .serving then "serving" else "not-ready" end][0] // "removed") end),
     old_pod: ([$app[] | select(.name == $m.pod) | if .deleting then "terminating" else .phase end][0] // "gone"),
     replacement: ([$app[] | select(.name != $m.pod and (.created | fromdateiso8601) > $m.partition_at - 1)
         | if .ready == "True" then "ready in \($zone[.node])" elif .node then "scheduled in \($zone[.node])" else "pending" end][0] // "none"),
     replacement_created: ([$app[] | select(.name != $m.pod and (.created | fromdateiso8601) > $m.partition_at - 1) | .created][0]),
     replicas_ready: ([$app[] | select(.deleting == null and .ready == "True")] | length),
     zones_ready: ([$app[] | select(.deleting == null and .ready == "True") | $zone[.node]] | unique | length),
     metrics_server, traefik}' "$dir/kube.jsonl" >"$dir/states.jsonl"

jq -sc --slurpfile meta "$dir/meta.json" --slurpfile etcd "$dir/etcd.jsonl" \
  --rawfile journal <(cat "$dir/k3s-journal.txt" 2>/dev/null) '
  $meta[0] as $m
  | (["node_ready", "endpoint", "old_pod", "replacement", "replicas_ready", "zones_ready", "metrics_server", "traefik"]) as $keys
  | [{at: $m.partition_at, event: "partition", zone: $m.zone}, {at: $m.heal_at, event: "heal", zone: $m.zone}]
    + [range(length) as $i | .[$i] as $s | (if $i > 0 then .[$i - 1] else null end) as $p
       | $keys[] | select($p == null or $p[.] != $s[.])
       | {at: $s.at, event: ., value: $s[.]} + (if . == "node_ready" then {since: $s.node_since} else {} end)
         + (if . == "replacement" and $s.replacement_created then {created: $s.replacement_created} else {} end)]
    + ($etcd | map({at, healthy: (if .etcd == null then null else [.etcd[] | select(.health)] | length end)})
       | [range(length) as $i | .[$i] as $s | select($i == 0 or .[$i - 1].healthy != $s.healthy)
          | {at: $s.at, event: "etcd_healthy_members", value: $s.healthy}])
    + [$journal | split("\n")[] | select(length > 0) | capture("^(?<at>[0-9.]+) .*(?<what>Main process exited|Started k3s)")
       | {at: (.at | tonumber), event: (if .what == "Started k3s" then "k3s_started" else "k3s_exited" end), zone: $m.zone}]
  | sort_by(.at)[]' "$dir/states.jsonl" >"$out/$label-timeline.jsonl"

jq -sc --slurpfile meta "$dir/meta.json" --arg run "$label" --slurpfile probe "$out/probe-$label.jsonl" \
  --slurpfile gaps <(jq -c 'select((.nodes | length) == 0 or (any(.pods[]?; .ns == "app") | not)) | .at' "$dir/kube.jsonl") '
  $meta[0] as $m
  | def first_at(f): [.[] | select(f) | .at][0];
    def from_partition(f): first_at(.at >= $m.partition_at - 2 and f) | if . then . - $m.partition_at else null end;
    def from_heal(f): first_at(.at >= $m.heal_at - 2 and f) | if . then . - $m.heal_at else null end;
  ($probe | map(select(.err)) | map(.sent / 1e9 - $m.partition_at)) as $failures
  | ([$probe[] | select(.ack) | .ack] + [$probe | map(.sent) | max] | sort | [., .[1:]] | transpose
     | map(select(.[1]) | (.[1] - .[0]) / 1e9) | max) as $pause
  | (map(select(.event == "etcd_healthy_members"))) as $e
  | {run: $run, zone: $m.zone, watcher: $m.watcher, etcd_leader_zone: $m.etcd_leader_zone,
     partition_seconds: ($m.heal_at - $m.partition_at),
     requests: ($probe | length), failed: ($failures | length),
     first_failure_s: ($failures | min), last_failure_s: ($failures | max), longest_pause_s: $pause,
     not_ready_s: from_partition(.event == "node_ready" and .value != "True"),
     watcher_api_gaps: ($gaps | length),
     k8s_not_ready_s: ([.[] | select(.event == "node_ready" and .value != "True" and .at >= $m.partition_at) | .since][0]
       | if . then fromdateiso8601 - $m.partition_at else null end),
     endpoint_removed_s: from_partition(.event == "endpoint" and .value != "ready" and .value != "no answer"),
     evicted_s: from_partition(.event == "old_pod" and .value == "terminating"),
     replacement_created_s: ([.[] | select(.event == "replacement" and .created) | .created][0]
       | if . then fromdateiso8601 - $m.partition_at else null end),
     replacement_scheduled_s: from_partition(.event == "replacement" and (.value | startswith("scheduled") or startswith("ready"))),
     replacement_ready_s: from_partition(.event == "replacement" and (.value | startswith("ready"))),
     metrics_server_down_s: from_partition(.event == "metrics_server" and .value == false),
     metrics_server_back_s: (first_at(.event == "metrics_server" and .value == false and .at >= $m.partition_at - 2) as $down
       | if $down then first_at(.event == "metrics_server" and .value == true and .at > $down) | if . then . - $m.partition_at else null end else null end),
     traefik_down_s: from_partition(.event == "traefik" and .value != "404" and .value != "200"),
     etcd_unhealthy_s: ($e | from_partition(.value != 3)),
     k3s_exited_s: from_partition(.event == "k3s_exited"),
     k3s_started_after_heal_s: from_heal(.event == "k3s_started"),
     node_ready_after_heal_s: from_heal(.event == "node_ready" and .value == "True"),
     etcd_healthy_after_heal_s: ($e | from_heal(.value == 3)),
     replicas_back_after_heal_s: from_heal(.event == "zones_ready" and .value == 3),
     replacement_ready_after_heal_s: from_heal(.event == "replacement" and (.value | startswith("ready")))}
' "$out/$label-timeline.jsonl" | tee -a "$out/app-partitions.jsonl"
