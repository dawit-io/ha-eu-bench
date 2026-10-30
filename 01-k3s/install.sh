#!/usr/bin/env bash
# Three K3s servers with embedded etcd, one per zone. The servers also run workloads.
source "$(dirname "$0")/../lib.sh"

ready

K3S_VERSION="${K3S_VERSION:-v1.35.4+k3s1}"
TOKEN_FILE="$STATE/.k3s-token"
[[ -f "$TOKEN_FILE" ]] || openssl rand -hex 32 >"$TOKEN_FILE"
token="$(cat "$TOKEN_FILE")"

first="$(node 0)"
n="$(count)"

for ((i = 0; i < n; i++)); do
  a="$(node "$i")"
  ip="$(field "$a" private_ip)"
  iface="$(on "$a" "ip -o -4 addr show to $ip | cut -d' ' -f2")"
  if ((i == 0)); then
    join="--cluster-init"
  else
    join="--server https://$(field "$first" private_ip):6443"
  fi
  echo "$(field "$a" zone): server $join" >&2

  on "$a" "curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=$K3S_VERSION K3S_TOKEN=$token sh -s - server $join \
    --node-ip $ip --advertise-address $ip --flannel-iface $iface \
    --tls-san $(field "$a" public_ip) \
    --node-label topology.kubernetes.io/zone=$(field "$a" zone) \
    --etcd-expose-metrics"
done

on "$first" "cat /etc/rancher/k3s/k3s.yaml" |
  sed "s/127.0.0.1/$(field "$first" public_ip)/" >"$STATE/kubeconfig"
chmod 600 "$STATE/kubeconfig"

export KUBECONFIG="$STATE/kubeconfig"
kubectl get nodes -L topology.kubernetes.io/zone

# K3s runs one copy of the cluster DNS: losing its zone stops every lookup by service name. SINGLE_DNS=1 keeps that default.
if [[ -z "${SINGLE_DNS:-}" ]]; then
  kubectl -n kube-system rollout status deployment/coredns --timeout=300s >/dev/null
  kubectl -n kube-system patch deployment coredns --type merge -p '{"spec": {"replicas": 3,
    "strategy": {"rollingUpdate": {"maxSurge": 0, "maxUnavailable": 1}},
    "template": {"spec": {"affinity": {"podAntiAffinity": {"requiredDuringSchedulingIgnoredDuringExecution": [
      {"topologyKey": "topology.kubernetes.io/zone", "labelSelector": {"matchLabels": {"k8s-app": "kube-dns"}}}]}}}}}}' >/dev/null
  kubectl -n kube-system rollout status deployment/coredns --timeout=300s >/dev/null
fi
