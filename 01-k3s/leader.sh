#!/usr/bin/env bash
# Print the zone of the etcd leader; with a zone, move the leader there first.
# Usage: 01-k3s/leader.sh [zone]
source "$(dirname "$0")/../lib.sh"

ETCD_VERSION="${ETCD_VERSION:-v3.6.7}"
tls=/var/lib/rancher/k3s/server/tls/etcd
endpoints="$(jq -r 'map("https://\(.private_ip):2379") | join(",")' "$NODES_FILE")"
first="$(node 0)"

etcdctl() {
  on "$first" "etcdctl --cacert=$tls/server-ca.crt --cert=$tls/client.crt --key=$tls/client.key --endpoints=$endpoints $*"
}

on "$first" "command -v etcdctl >/dev/null || curl -sfL https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/etcd-$ETCD_VERSION-linux-amd64.tar.gz |
  tar xz -C /usr/local/bin --strip-components=1 etcd-$ETCD_VERSION-linux-amd64/etcdctl"

# endpoint, member id, then the first true/false column is "is leader"
members() {
  etcdctl endpoint status -w simple |
    awk -F', ' '{ for (i = 3; i <= NF; i++) if ($i == "true" || $i == "false") { print $1, $2, $i; break } }'
}

zone_of() { jq -r --arg ip "$1" '.[] | select(.private_ip == $ip) | .zone' "$NODES_FILE"; }

if [[ -n "${1:-}" ]]; then
  ip="$(jq -r --arg z "$1" '.[] | select(.zone == $z) | .private_ip' "$NODES_FILE")"
  id="$(members | awk -v e="https://$ip:2379" '$1 == e { print $2 }')"
  current="$(members | awk '$3 == "true" { print $2 }')"
  for ((try = 0; try < 20; try++)); do
    [[ "$id" == "$current" ]] && break
    etcdctl move-leader "$id" >&2 2>/dev/null || sleep 3
    current="$(members | awk '$3 == "true" { print $2 }')"
  done
fi

leader="$(members | awk '$3 == "true" { print $1 }' | sed 's|https://||; s|:2379||')"
zone_of "$leader"
