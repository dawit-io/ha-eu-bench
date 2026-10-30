#!/usr/bin/env bash
# etcd's own WAL fsync and backend commit times during each step, from the histograms bench/stats.sh saved.
# The percentiles come from buckets: le_ms is the upper bound of the bucket that holds them, ms interpolates
# inside it as Prometheus does. One line per step and zone, then one line with every step and zone summed.
# Usage: bench/etcd.sh results/<run>
set -euo pipefail

jq -sc '
  def num: if . == "+Inf" then infinite else tonumber end;
  def minus($b): if .count < $b.count then . else
    {count: (.count - $b.count), sum: (.sum - $b.sum),
     buckets: [.buckets as $a | range($a | length) | {le: $a[.].le, count: ($a[.].count - $b.buckets[.].count)}]} end;
  def plus($b): if . == null then $b else
    {count: (.count + $b.count), sum: (.sum + $b.sum),
     buckets: [.buckets as $a | range($a | length) | {le: $a[.].le, count: ($a[.].count + $b.buckets[.].count)}]} end;
  def quantile($q): (.count * $q) as $rank | .buckets | sort_by(.le | num)
    | [foreach .[] as $x ({prev: 0, prev_le: 0, x: null}; {prev: (.x.count // 0), prev_le: (.x.le // "0" | num), x: $x})]
    | map(select(.x.count >= $rank and .x.count > 0)) | first
    | if . == null then null
      elif (.x.le | num) == infinite then {le_ms: null, ms: (.prev_le * 1000)}
      else {le_ms: ((.x.le | num) * 1000),
            ms: ((.prev_le + ((.x.le | num) - .prev_le) * ($rank - .prev) / (.x.count - .prev)) * 1000)} end;
  def report: {count, mean_ms: (if .count > 0 then .sum / .count * 1000 else null end),
               p50: quantile(0.5), p99: quantile(0.99)};
  [group_by(.step, .node)[]
   | (map(select(.phase == "before")) | last) as $b | (map(select(.phase == "after")) | last) as $a
   | select($b and $a)
   | {step: $a.step, zone: $a.zone, at: $b.at, reset: ($a.wal_fsync.count < $b.wal_fsync.count),
      wal: ($a.wal_fsync | minus($b.wal_fsync)), commit: ($a.backend_commit | minus($b.backend_commit)),
      leader_changes: (if $a.leader_changes < $b.leader_changes then $a.leader_changes else $a.leader_changes - $b.leader_changes end),
      proposals_failed: (if $a.proposals_failed < $b.proposals_failed then $a.proposals_failed else $a.proposals_failed - $b.proposals_failed end)}]
  | sort_by(.at)
  | (.[] | {step, zone, reset, wal_fsync: (.wal | report), backend_commit: (.commit | report), leader_changes, proposals_failed}),
    (reduce .[] as $s ({wal: null, commit: null}; {wal: (.wal | plus($s.wal)), commit: (.commit | plus($s.commit))})
     | select(.wal) | {step: "all", zone: "all", wal_fsync: (.wal | report), backend_commit: (.commit | report)})
' "$1/etcd-metrics.jsonl"
