#!/usr/bin/env bash
# Build the probe, copy it to the node of <zone> and run it there. Pick a zone you are not going to break.
# Usage: probe/run.sh <zone> pg|kube|verify [probe flags]
source "$(dirname "$0")/../lib.sh"

zone="$1"
mode="$2"
shift 2
out="$(run_dir)/probe-${LABEL:-$mode-$zone-$(date -u +%H%M%S)}.jsonl"
[[ -e "$out" ]] && { echo "$out exists: a run never overwrites another, set RUN_DIR or LABEL" >&2; exit 1; }

(cd "$ROOT/probe" && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o "$STATE/.probe-$mode" .)

a="$(node_in "$zone")"
target="$(field "$a" ssh_user)@$(field "$a" public_ip)"
scp -q "${SSH_OPTS[@]}" "$STATE/.probe-$mode" "$target:/tmp/probe-$mode"

on "$a" "/tmp/probe-$mode $mode $*" >"$out"
