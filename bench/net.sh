#!/usr/bin/env bash
# Round-trip time and TCP throughput between every pair of nodes, over the private network.
source "$(dirname "$0")/../lib.sh"

ready
out="$(run_dir)/net.jsonl"
n="$(count)"

tcp() {
  on "$1" "iperf3 -J -t $IPERF_SECONDS $3 -c $2" | jq '{
    average_gbps: (.end.sum_received.bits_per_second / 1e9),
    sustained_gbps: ([.intervals[-5:][].sum.bits_per_second] | add / length / 1e9)
  }'
}

for ((i = 0; i < n; i++)); do
  on "$(node "$i")" "pgrep -x iperf3 >/dev/null || iperf3 -s -D"
done

for ((i = 0; i < n; i++)); do
  for ((j = i + 1; j < n; j++)); do
    a="$(node "$i")"
    b="$(node "$j")"
    dst="$(field "$b" private_ip)"
    echo "$(field "$a" zone) -> $(field "$b" zone)" >&2

    rtt="$(on "$a" "ping -c $PINGS -i 0.2 $dst" | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | jq -s 'sort | {
      replies: length,
      p50_ms: .[(length * 0.50 | floor)],
      p99_ms: .[(length * 0.99 | floor)]
    }')"
    tcp1="$(tcp "$a" "$dst" "")"
    tcp4="$(tcp "$a" "$dst" "-P 4")"

    jq -nc --arg from "$(field "$a" zone)" --arg to "$(field "$b" zone)" --argjson sent "$PINGS" \
      --argjson rtt "$rtt" --argjson tcp1 "$tcp1" --argjson tcp4 "$tcp4" \
      '{from: $from, to: $to, sent: $sent} + $rtt + {tcp_1_stream: $tcp1, tcp_4_streams: $tcp4}' |
      tee -a "$out"
  done
done
