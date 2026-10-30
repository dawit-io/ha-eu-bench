#!/usr/bin/env bash
# Break one zone, the same way on every provider.
#   partition <zone> [seconds]  the zone's nodes stay up but reach nobody and nobody reaches them;
#                               only your SSH passes. Heals itself after the given time (default 600 s).
#   heal <zone>                 end the partition now.
#   crash <zone>                instant reset of the zone's nodes, nothing flushed to disk; they boot again.
source "$(dirname "$0")/../lib.sh"

action="$1"
zone="$2"
seconds="${3:-600}"
operator_ip="${OPERATOR_IP:-$(curl -4 -s https://ifconfig.me)}"
out="$(run_dir)/faults.jsonl"

partition_rules="table inet ha_fault {
  chain input { type filter hook input priority -10; policy drop; iif lo accept; ip saddr $operator_ip tcp dport 22 accept; }
  chain forward { type filter hook forward priority -10; policy drop; }
  chain output { type filter hook output priority -10; policy drop; oif lo accept; ip daddr $operator_ip tcp sport 22 accept; }
}"

for ((i = 0; i < $(count); i++)); do
  a="$(node "$i")"
  [[ "$(field "$a" zone)" == "$zone" ]] || continue

  case "$action" in
    partition)
      at="$(on "$a" "systemctl stop ha-fault-heal.timer 2>/dev/null || true
        echo '$partition_rules' | nft -f -
        systemd-run --quiet --unit ha-fault-heal --on-active=${seconds}s nft delete table inet ha_fault
        date +%s.%N")"
      ;;
    heal)
      at="$(on "$a" "nft delete table inet ha_fault 2>/dev/null || true
        systemctl stop ha-fault-heal.timer 2>/dev/null || true
        date +%s.%N")"
      ;;
    crash)
      at="$(on "$a" "echo 1 > /proc/sys/kernel/sysrq; date -d '+1 second' +%s.%N
        (sleep 1; echo b > /proc/sysrq-trigger) >/dev/null 2>&1 &")"
      ;;
    *)
      echo "usage: faults/fault.sh partition|heal|crash <zone> [seconds]" >&2
      exit 1
      ;;
  esac

  jq -nc --arg action "$action" --arg zone "$zone" --arg node "$(field "$a" name)" --argjson at "$at" \
    '{action: $action, zone: $zone, node: $node, at: $at}' | tee -a "$out"
done
