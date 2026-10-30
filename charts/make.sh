#!/usr/bin/env bash
# Charts for the articles, from one results folder per provider. Writes SVG files to charts/out/.
# Usage: charts/make.sh results/<hetzner run> results/<scaleway run> results/<ovh run>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/out"
data="$(mktemp -d)"
trap 'rm -rf "$data"' EXIT
mkdir -p "$out"

style='set terminal svg size 860,460 dynamic font "Helvetica,13" background "#ffffff"
set border 3 lc rgb "#555555"; set tics nomirror; set grid ytics lc rgb "#e5e5e5"
set style fill solid 0.9 border -1; set boxwidth 0.7; set key top left; set xtics rotate by -30'

for run in "$@"; do
  p="$(jq -r '.[0].provider' "$run/nodes.json")"

  [[ -f "$run/net.jsonl" ]] && jq -r --arg p "$p" '[$p, "\(.from)-\(.to)", .p50_ms, .p99_ms,
    .tcp_1_stream.sustained_gbps] | @tsv' "$run/net.jsonl" >>"$data/net.tsv"
  [[ -f "$run/disk.jsonl" ]] && jq -r --arg p "$p" '[$p, .zone, .fsync_p50_ms, .fsync_p99_ms] | @tsv' \
    "$run/disk.jsonl" >>"$data/disk.tsv"

  "$here/../bench/summary.sh" "$run" | jq -r --arg p "$p" '[$p, .run, .p50_ms, .p99_ms, .longest_pause_ms / 1000,
    .failed] | @tsv' >>"$data/probe.tsv"

  for f in "$run"/probe-*-crash*.jsonl "$run"/probe-*-partition*.jsonl "$run"/probe-partition-*.jsonl "$run"/probe-crash-*.jsonl; do
    [[ "$f" == *-verify.jsonl ]] && continue
    [[ -f "$f" ]] || continue
    name="$p-$(basename "$f" .jsonl | sed 's/^probe-//')"
    jq -sr '(.[0].sent) as $t0 | .[] | select(.ack) | [(.sent - $t0) / 1e9, (.ack - .sent) / 1e6] | @tsv' \
      "$f" >"$data/$name.tsv"
    fault_at="$(jq -sr --slurpfile p <(jq -s '[.[0].sent, .[-1].sent]' "$f") \
      '($p[0][0] / 1e9) as $from | ($p[0][1] / 1e9) as $to | ([.[] | select(.at >= $from and .at <= $to)][0].at // empty) - $from' \
      "$run/faults.jsonl")"
    marker=""
    [[ -n "$fault_at" ]] && marker="set arrow from $fault_at, graph 0 to $fault_at, graph 1 nohead dt 2 lc rgb '#d1495b'
set label 'fault' at $fault_at, graph 0.95 offset 0.5,0 tc rgb '#d1495b'"
    gnuplot <<EOF
$style
set output "$out/timeline-$name.svg"
set title "$name: latency of each acknowledged write"
set xlabel "seconds"; set ylabel "ms (log)"; set logscale y; set xtics norotate
$marker
plot "$data/$name.tsv" using 1:2 with points pt 7 ps 0.3 lc rgb "#2a6fdb" notitle
EOF
  done
done

bars() {
  local file="$1" title="$2" ylabel="$3" columns="$4" name="$5"
  [[ -s "$file" ]] || return 0
  gnuplot <<EOF
$style
set output "$out/$name.svg"
set title "$title"; set ylabel "$ylabel"; set yrange [0:*]
set datafile separator "\t"
plot "$file" $columns
EOF
}

bars "$data/net.tsv" "Round trip between zones (p50, p99)" "ms" \
  'using 0:3:xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#2a6fdb" title "p50", "" using 0:4 with points pt 7 lc rgb "#d1495b" title "p99"' rtt
bars "$data/net.tsv" "Sustained TCP throughput between zones, one stream" "Gbit/s" \
  'using 0:5:xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#2a6fdb" notitle' throughput
bars "$data/disk.tsv" "fsync after a 4K write, disk behind /var/lib (p50, p99)" "ms" \
  'using 0:3:xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#2a6fdb" title "p50", "" using 0:4 with points pt 7 lc rgb "#d1495b" title "p99"' fsync

grep $'\tlatency-leader-' "$data/probe.tsv" >"$data/leader.tsv" || true
bars "$data/leader.tsv" "Kubernetes API write latency by etcd leader zone (p50, p99)" "ms" \
  'using 0:3:xtic(stringcolumn(1)." ".substr(stringcolumn(2), 16, 99)) with boxes lc rgb "#2a6fdb" title "p50", "" using 0:4 with points pt 7 lc rgb "#d1495b" title "p99"' api-latency

grep -E $'\t(partition|crash)-' "$data/probe.tsv" >"$data/k3s-faults.tsv" || true
bars "$data/k3s-faults.tsv" "Longest pause of Kubernetes API writes during a fault" "seconds" \
  'using 0:5:xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#d1495b" notitle' api-pause

grep -E $'\t[a-z0-9-]+-commit\t' "$data/probe.tsv" >"$data/commit.tsv" || true
bars "$data/commit.tsv" "Postgres commit latency, one client (p50, p99)" "ms" \
  'using 0:3:xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#2a6fdb" title "p50", "" using 0:4 with points pt 7 lc rgb "#d1495b" title "p99"' commit

grep -E $'\t(single|async|sync|sync-2|sync-2-preferred)-(crash|partition)' "$data/probe.tsv" | grep -v -- '-read'$'\t' \
  >"$data/failover.tsv" || true
bars "$data/failover.tsv" "Postgres: longest pause of writes when the primary is lost" "seconds" \
  'using 0:5:xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#d1495b" notitle' failover

awk -F'\t' 'NR == FNR { if ($2 ~ /-read$/) read[$1 "\t" substr($2, 1, length($2) - 5)] = $5; next }
  ($1 "\t" $2) in read { print $1 "\t" $2 "\t" $5 "\t" read[$1 "\t" $2] }' "$data/probe.tsv" "$data/probe.tsv" >"$data/reads.tsv"
bars "$data/reads.tsv" "Primary's zone lost: longest pause of writes and of reads from the copies" "seconds" \
  'using ($0 - 0.2):3:(0.4):xtic(stringcolumn(1)." ".stringcolumn(2)) with boxes lc rgb "#d1495b" title "writes", "" using ($0 + 0.2):4:(0.4) with boxes lc rgb "#2a6fdb" title "reads"' reads

echo "charts in $out"
