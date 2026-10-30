#!/usr/bin/env bash
# Fine-grained counters on every node, recorded until stop. Kept in memory on the node (/run/sample),
# so the disk being measured sees no extra writes.
#   samples/<zone>.cpu   every 100 ms: time (µs), the cpu line of /proc/stat, the /proc/diskstats line of the partition under etcd
#   samples/<zone>.disk  every 100 ms: time (µs), the /proc/diskstats line of the whole disk, which alone counts flushes
#   samples/<zone>.etcd  every 1 s: time (µs), WAL fsync and backend commit histograms, is_leader; names in <zone>.names
#   samples/<zone>.clock systemd-timesyncd's offset at start and stop, to align clocks between nodes
# bench/steal.py joins them to the probe writes.
# Usage: bench/sample.sh start|stop
source "$(dirname "$0")/../lib.sh"

# shellcheck disable=SC2016
cpu_loop='exec {fd}<> <(:)
while :; do
  t=$EPOCHREALTIME
  read -r _ c </proc/stat
  while read -r _ _ name rest; do
    [[ $name == "$1" ]] && d=$rest
    [[ $name == "$2" ]] && w=$rest
  done </proc/diskstats
  echo "$t $c | $d" >&3
  echo "$t | $w" >&4
  read -t 0.1 -u $fd || true
done 3>>/run/sample/cpu 4>>/run/sample/disk'

# shellcheck disable=SC2016
etcd_loop='families="^etcd_disk_(wal_fsync|backend_commit)_duration_seconds|^etcd_server_is_leader "
while :; do
  t=$EPOCHREALTIME
  curl -s --max-time 0.8 http://127.0.0.1:2381/metrics | grep -E "$families" |
    awk -v t="$t" "{ n = n \" \" \$1; v = v \" \" \$2 } END { print n > \"/run/sample/names\"; print t v }"
  sleep 0.98
done >>/run/sample/etcd'

case "$1" in
  start)
    for ((i = 0; i < $(count); i++)); do
      a="$(node "$i")"
      on "$a" "systemctl stop sample-cpu sample-etcd sample-disk 2>/dev/null; systemctl reset-failed sample-cpu sample-etcd sample-disk 2>/dev/null; rm -rf /run/sample; mkdir -p /run/sample
        dev=\$(basename \"\$(findmnt -no SOURCE --target /var/lib/rancher)\")
        disk=\$(lsblk -no pkname \"/dev/\$dev\")
        echo \"\$dev\" >/run/sample/device
        echo \"\$disk\" >/run/sample/disk-device
        printf '%s\n' $(printf '%q' "$cpu_loop") >/run/sample/cpu.sh
        printf '%s\n' $(printf '%q' "$etcd_loop") >/run/sample/etcd.sh
        (date +%s.%N; timedatectl timesync-status) >/run/sample/clock
        systemd-run -q --unit sample-cpu -p Nice=-5 bash /run/sample/cpu.sh \"\$dev\" \"\$disk\"
        systemd-run -q --unit sample-etcd bash /run/sample/etcd.sh"
    done
    ;;
  stop)
    out="$(run_dir)/samples"
    mkdir -p "$out"
    for ((i = 0; i < $(count); i++)); do
      a="$(node "$i")"
      zone="$(field "$a" zone)"
      on "$a" "systemctl stop sample-cpu sample-etcd sample-disk 2>/dev/null; (date +%s.%N; timedatectl timesync-status) >>/run/sample/clock"
      for f in cpu disk etcd names device disk-device clock; do
        on "$a" "cat /run/sample/$f" >"$out/$zone.$f"
      done
    done
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 1 ;;
esac
