#!/usr/bin/env bash
# One line per probe run: acknowledged writes, failures, latency percentiles, longest pause.
# The pause counts the end of the run too: writes that never come back are one long pause.
# Usage: bench/summary.sh results/<run>
set -euo pipefail

for f in "$1"/probe-*.jsonl; do
  [[ -e "$f" && "$f" != *-verify.jsonl ]] || continue
  jq -sc --arg run "$(basename "$f" .jsonl | sed 's/^probe-//')" '
    [.[] | select(.ack)] as $ok
    | ($ok | map((.ack - .sent) / 1e6) | sort) as $lat
    | (($ok | map(.ack)) + [map(.sent) | max] | sort | [., .[1:]] | transpose
       | map(select(.[1]) | (.[1] - .[0]) / 1e6) | max) as $pause
    | {run: $run, acknowledged: ($ok | length), failed: (map(select(.err)) | length),
       p50_ms: $lat[($lat | length) * 0.5 | floor], p99_ms: $lat[($lat | length) * 0.99 | floor],
       longest_pause_ms: $pause}' "$f"
done
