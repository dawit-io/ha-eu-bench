#!/usr/bin/env bash
# Wait until every etcd member answers its health check, then print when that happened (epoch seconds).
# Ask from a zone you are not breaking. Fails after the given time (default 600 s).
# Usage: 01-k3s/healthy.sh [zone] [seconds]
source "$(dirname "$0")/../lib.sh"

ETCD_VERSION="${ETCD_VERSION:-v3.6.7}"
tls=/var/lib/rancher/k3s/server/tls/etcd
endpoints="$(jq -r 'map("https://\(.private_ip):2379") | join(",")' "$NODES_FILE")"
a="$(node_in "${1:-$(field "$(node 0)" zone)}")"
seconds="${2:-600}"

on "$a" "command -v etcdctl >/dev/null || curl -sfL https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-amd64.tar.gz |
  tar xz -C /usr/local/bin --strip-components=1 etcd-$ETCD_VERSION-linux-amd64/etcdctl"

on "$a" "end=\$((\$(date +%s) + $seconds))
  until etcdctl --cacert=$tls/server-ca.crt --cert=$tls/client.crt --key=$tls/client.key --endpoints=$endpoints \
      --command-timeout=2s endpoint health >/dev/null 2>&1; do
    [ \$(date +%s) -lt \$end ] || exit 1
    sleep 2
  done
  date +%s.%N"
