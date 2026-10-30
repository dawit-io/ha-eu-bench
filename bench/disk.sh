#!/usr/bin/env bash
# Latency of the fsync that follows each 4K write, on the disk behind /var/lib:
# where K3s keeps etcd and where Postgres data will live. All nodes at once: disks are independent.
source "$(dirname "$0")/../lib.sh"

ready
out="$(run_dir)/disk.jsonl"

measure() {
  local a="$1" fio cpu device
  fio="$(on "$a" "fio --name=fsync --filename=/var/lib/ha-bench.fio --rw=randwrite --bs=4k \
    --iodepth=1 --fsync=1 --direct=1 --ioengine=libaio --size=$FIO_SIZE --runtime=$FIO_SECONDS --time_based \
    --output-format=json; rm -f /var/lib/ha-bench.fio")"
  cpu="$(on "$a" "lscpu | sed -n 's/^Model name: *//p'")"
  device="$(on "$a" "findmnt -no SOURCE --target /var/lib")"

  jq -c --arg zone "$(field "$a" zone)" --arg cpu "$cpu" --arg device "$device" '.jobs[0] | {
    zone: $zone,
    cpu: $cpu,
    device: $device,
    fsync_p50_ms: (.sync.lat_ns.percentile["50.000000"] / 1e6),
    fsync_p99_ms: (.sync.lat_ns.percentile["99.000000"] / 1e6),
    write_iops: .write.iops
  }' <<<"$fio" | tee -a "$out"
}

for ((i = 0; i < $(count); i++)); do
  measure "$(node "$i")" &
done
wait
