#!/usr/bin/env bash
# Volumes for apps with one writer, replicated across zones with DRBD (Piraeus/LINSTOR).
# Copies live in the first two zones; the third holds only the quorum vote and the LINSTOR controllers,
# so losing a data zone never takes the controllers with it.
#   install    kernel headers, a volume group per data node, Piraeus, two StorageClasses
#   disk       fsync and throughput on local-path, one DRBD copy, two DRBD copies in two zones
#   failover   an app appends numbered lines with fsync; its zone is cut off for 180 s
#   postgres   one plain Postgres (no operator) on a two-zone volume: commit latency, then its zone is cut off
#              for 180 s REPEAT times while the probe writes; every acknowledged row is looked for afterwards
# The volume group sits on DEVICE when that disk exists, otherwise on a loop file on the system disk.
# Usage: 03-volumes/run.sh [install] [disk] [failover] [postgres]
source "$(dirname "$0")/../lib.sh"

PIRAEUS_VERSION="${PIRAEUS_VERSION:-v2.12.0}"
DEVICE="${DEVICE:-/dev/sdb}"
export KUBECONFIG="$STATE/kubeconfig"
read -ra zones <<<"$(jq -r 'map(.zone) | join(" ")' "$NODES_FILE")"
steps=("$@")
[[ ${#steps[@]} -gt 0 ]] || steps=(install disk failover)
out="$(run_dir)"
drbd='property.linstor.csi.linbit.com/DrbdOptions'

storage_class() {
  cat <<EOF
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata: {name: $1}
provisioner: linstor.csi.linbit.com
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
parameters:
  linstor.csi.linbit.com/storagePool: drbd
  linstor.csi.linbit.com/placementCount: "$2"
  linstor.csi.linbit.com/allowRemoteVolumeAccess: "false"
  linstor.csi.linbit.com/replicasOnDifferent: Aux/topology/topology.kubernetes.io/zone
  csi.storage.k8s.io/fstype: ext4
  $drbd/auto-quorum: suspend-io
  $drbd/Resource/on-no-data-accessible: suspend-io
  $drbd/Resource/on-suspended-primary-outdated: force-secondary
  $drbd/Net/rr-conflict: retry-connect
---
EOF
}

install() {
  local i a
  for ((i = 0; i < $(count); i++)); do
    a="$(node "$i")"
    on "$a" "export DEBIAN_FRONTEND=noninteractive; apt-get install -y -qq lvm2 \"linux-headers-\$(uname -r)\" >/dev/null"
    [[ "$(field "$a" zone)" == "${zones[2]}" ]] && continue
    on "$a" "vgs drbd >/dev/null 2>&1 && exit 0
      if [ -b $DEVICE ]; then dev=$DEVICE; else
        fallocate -l 16G /var/lib/drbd-pool.img
        dev=\$(losetup --find --show --direct-io=on --sector-size 4096 /var/lib/drbd-pool.img); fi
      pvcreate -q \$dev && vgcreate -q drbd \$dev"
    kubectl label node "$(field "$a" name)" ha-bench/copies=true --overwrite >/dev/null
  done

  kubectl apply --server-side -f \
    "https://github.com/piraeusdatastore/piraeus-operator/releases/download/$PIRAEUS_VERSION/manifest.yaml" >/dev/null
  kubectl -n piraeus-datastore wait pod -l app.kubernetes.io/component=piraeus-operator --for=condition=Ready --timeout=300s >/dev/null

  local controllers="{podTemplate: {spec: {nodeSelector: {topology.kubernetes.io/zone: ${zones[2]}}}}}"
  { cat <<EOF
apiVersion: piraeus.io/v1
kind: LinstorCluster
metadata: {name: linstorcluster}
spec:
  highAvailabilityController: {enabled: true}
  controller: $controllers
  csiController: $controllers
  affinityController: $controllers
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata: {name: host-network}
spec:
  podTemplate: {spec: {hostNetwork: true}}
---
apiVersion: piraeus.io/v1
kind: LinstorSatelliteConfiguration
metadata: {name: pool}
spec:
  nodeSelector: {ha-bench/copies: "true"}
  storagePools: [{name: drbd, lvmPool: {volumeGroup: drbd}}]
---
EOF
    storage_class one-copy 1
    storage_class two-zones 2
  } | kubectl apply -f - >/dev/null

  until kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor storage-pool list 2>/dev/null |
    grep -c " drbd " | grep -qx 2; do sleep 10; done
  kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor node list
}

# Waits until <copies> disks hold the data and none is behind, then logs the state the measurement starts from.
synced() {
  local copies="$1" table
  until table="$(kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list-volumes 2>/dev/null)" &&
    [[ "$(grep -c UpToDate <<<"$table")" -ge "$copies" ]] &&
    ! grep -q -E 'SyncTarget|SyncSource|Inconsistent|Negotiating|Connecting|Outdated|Unknown' <<<"$table" &&
    { [[ "$copies" -lt 2 ]] || ! grep pvc- <<<"$table" | grep -qv Established; }; do sleep 5; done
  printf '%s %s\n%s\n' "$(date -u +%FT%TZ)" "$2" "$table" >>"$out/volumes-drbd-state.log"
}

copies() { case "$1" in two-zones) echo 2 ;; one-copy) echo 1 ;; *) echo 0 ;; esac; }

disk() {
  local class fsync seq
  for class in local-path one-copy two-zones; do
    kubectl delete pod fio --ignore-not-found --wait=true >/dev/null
    kubectl delete pvc fio --ignore-not-found --wait=true >/dev/null
    kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: fio}
spec: {accessModes: [ReadWriteOnce], storageClassName: $class, resources: {requests: {storage: 4Gi}}}
---
apiVersion: v1
kind: Pod
metadata: {name: fio}
spec:
  nodeSelector: {topology.kubernetes.io/zone: ${zones[0]}}
  restartPolicy: Never
  volumes: [{name: data, persistentVolumeClaim: {claimName: fio}}]
  containers:
    - name: fio
      image: alpine:3.20
      volumeMounts: [{name: data, mountPath: /data}]
      command: [sh, -c, "until apk add -q fio; do sleep 5; done; sleep 3600"]
EOF
    kubectl wait pod fio --for=condition=Ready --timeout=600s >/dev/null
    until kubectl exec fio -- sh -c 'command -v fio' >/dev/null 2>&1; do sleep 2; done
    synced "$(copies "$class")" "fio $class"
    fsync="$(kubectl exec fio -- fio --name=fsync --filename=/data/fio --rw=randwrite --bs=4k --iodepth=1 --fsync=1 \
      --direct=1 --ioengine=libaio --size="$FIO_SIZE" --runtime="$FIO_SECONDS" --time_based --output-format=json)"
    seq="$(kubectl exec fio -- fio --name=seq --filename=/data/fio --rw=write --bs=1M --iodepth=8 \
      --direct=1 --ioengine=libaio --size="$FIO_SIZE" --runtime=30 --time_based --output-format=json)"
    jq -nc --arg class "$class" --argjson f "$fsync" --argjson s "$seq" '{
      class: $class,
      fsync_p50_ms: ($f.jobs[0].sync.lat_ns.percentile["50.000000"] / 1e6),
      fsync_p99_ms: ($f.jobs[0].sync.lat_ns.percentile["99.000000"] / 1e6),
      write_iops: $f.jobs[0].write.iops,
      sequential_write_mb_s: ($s.jobs[0].write.bw / 1024)
    }' | tee -a "$out/volumes-disk.jsonl"
  done
  kubectl delete pod fio --wait=true >/dev/null
  kubectl delete pvc fio >/dev/null
}

# The writer prints "ack <n> <ms>" only after fsync returned; the lines are streamed to this machine as they come,
# so the acknowledgements survive the node. After the fault, the file is read back on whichever node holds it.
failover() {
  local class name data_zones zone after stream
  for class in ${FAILOVER_CLASSES:-two-zones local-path}; do
    name="writer-$class"
    data_zones="${zones[0]}, ${zones[1]}"
    kubectl apply -f - >/dev/null <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: $name}
spec:
  serviceName: $name
  replicas: 1
  selector: {matchLabels: {app: $name}}
  template:
    metadata: {labels: {app: $name}}
    spec:
      terminationGracePeriodSeconds: 5
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms: [{matchExpressions: [{key: topology.kubernetes.io/zone, operator: In, values: [$data_zones]}]}]
      containers:
        - name: writer
          image: debian:bookworm-slim
          volumeMounts: [{name: data, mountPath: /data}]
          command:
            - bash
            - -c
            - |
              n=\$(tail -n1 /data/log 2>/dev/null || echo 0)
              while true; do
                n=\$((n + 1))
                echo \$n | dd of=/data/log oflag=append conv=notrunc,fsync status=none && echo "ack \$n \$(date +%s%3N)"
                sleep 0.05
              done
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {accessModes: [ReadWriteOnce], storageClassName: $class, resources: {requests: {storage: 1Gi}}}
EOF
    kubectl wait pod "$name-0" --for=condition=Ready --timeout=600s >/dev/null
    synced "$(copies "$class")" "failover $class"
    zone="$(pod_zone default "$name-0")"
    kubectl logs -f "$name-0" >"$out/volumes-$class-before.log" 2>/dev/null &
    stream=$!
    sleep 20
    "$ROOT/faults/fault.sh" partition "$zone" 180 >/dev/null
    sleep 200
    ready
    kubectl wait pod "$name-0" --for=condition=Ready --timeout=600s >/dev/null || true
    sleep 15
    kill "$stream" 2>/dev/null || true
    kubectl logs "$name-0" >"$out/volumes-$class-after.log"
    after="$(pod_zone default "$name-0")"
    kubectl exec "$name-0" -- cat /data/log >"$out/volumes-$class-file.txt"

    jq -nc --arg class "$class" --arg before "$zone" --arg after "$after" \
      --rawfile b "$out/volumes-$class-before.log" --rawfile a "$out/volumes-$class-after.log" \
      --rawfile file "$out/volumes-$class-file.txt" '
      def acks: split("\n") | map(select(startswith("ack ")) | split(" ") | {n: (.[1] | tonumber), ms: (.[2] | tonumber)});
      ($b + $a | acks | unique_by(.n) | sort_by(.ms)) as $acks
      | ($file | split("\n") | map(select(. != "") | tonumber)) as $rows
      | {class: $class, zone_before: $before, zone_after: $after,
         acknowledged: ($acks | length),
         pause_s: ([$acks, $acks[1:]] | transpose | map(select(.[1]) | (.[1].ms - .[0].ms) / 1000) | max),
         acknowledged_and_lost: ($acks | map(.n) - $rows | length),
         written_twice: (($rows | length) - ($rows | unique | length))}' | tee -a "$out/volumes-failover.jsonl"

    kubectl delete statefulset "$name" --wait=true >/dev/null
    kubectl delete pvc "data-$name-0" --wait=true >/dev/null
  done
}

during() {
  mkdir -p "$1"
  kubectl get pods -A -o wide >"$1/pods.txt" 2>&1
  kubectl get nodes >"$1/nodes.txt" 2>&1
  kubectl describe pod pg-0 >"$1/pg-0.txt" 2>&1
  kubectl get volumeattachments -o wide >"$1/volumeattachments.txt" 2>&1
  kubectl -n piraeus-datastore exec deploy/linstor-controller -- linstor resource list-volumes >"$1/drbd.txt" 2>&1
  kubectl get events -A --sort-by=.lastTimestamp >"$1/events.txt" 2>&1
}

postgres() {
  local r zone writer host dsn
  kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Service
metadata: {name: pg}
spec: {selector: {app: pg}, ports: [{port: 5432}]}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: pg}
spec:
  serviceName: pg
  replicas: 1
  selector: {matchLabels: {app: pg}}
  template:
    metadata: {labels: {app: pg}}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms: [{matchExpressions: [{key: topology.kubernetes.io/zone, operator: In, values: [${zones[0]}, ${zones[1]}]}]}]
      containers:
        - name: postgres
          image: postgres:17
          env: [{name: POSTGRES_PASSWORD, value: bench}, {name: PGDATA, value: /var/lib/postgresql/data/pgdata}]
          readinessProbe: {exec: {command: [pg_isready, -U, postgres]}, periodSeconds: 2}
          volumeMounts: [{name: data, mountPath: /var/lib/postgresql/data}]
  volumeClaimTemplates:
    - metadata: {name: data}
      spec: {accessModes: [ReadWriteOnce], storageClassName: two-zones, resources: {requests: {storage: 5Gi}}}
EOF
  kubectl wait pod pg-0 --for=condition=Ready --timeout=600s >/dev/null
  synced 2 "postgres commit"
  host="$(kubectl get service pg -o jsonpath='{.spec.clusterIP}')"
  dsn="postgres://postgres:bench@$host:5432/postgres?connect_timeout=2"

  zone="$(pod_zone default pg-0)"
  writer="$(other_zone "$zone")"
  LABEL=pg-drbd-commit "$ROOT/probe/run.sh" "$writer" pg -dsn "$dsn" -interval 0s -duration "${PROBE_SECONDS}s"
  LABEL=pg-drbd-commit-same-zone "$ROOT/probe/run.sh" "$zone" pg -dsn "$dsn" -interval 0s -duration "${PROBE_SECONDS}s"

  for ((r = 1; r <= ${REPEAT:-1}; r++)); do
    synced 2 "postgres partition $r"
    zone="$(pod_zone default pg-0)"
    writer="$(other_zone "$zone")"
    LABEL="pg-drbd-partition-$r" "$ROOT/probe/run.sh" "$writer" pg -dsn "$dsn" -duration 300s &
    sleep 20
    "$ROOT/faults/fault.sh" partition "$zone" 180 >/dev/null
    (sleep 120 && during "$out/postgres-partition-$r-during") &
    wait
    ready
    kubectl wait pod pg-0 --for=condition=Ready --timeout=600s >/dev/null || true
    LABEL="pg-drbd-partition-$r-verify" "$ROOT/probe/run.sh" "$writer" verify -dsn "$dsn" -acks /dev/stdin \
      <"$out/probe-pg-drbd-partition-$r.jsonl" || true
    jq -nc --arg run "pg-drbd-partition-$r" --arg before "$zone" --arg after "$(pod_zone default pg-0)" \
      '{run: $run, zone_before: $before, zone_after: $after}' | tee -a "$out/volumes-postgres.jsonl"
  done

  kubectl delete statefulset pg --wait=true >/dev/null
  kubectl delete pvc data-pg-0 --wait=true >/dev/null
  kubectl delete service pg >/dev/null
}

for step in "${steps[@]}"; do "$step"; done
