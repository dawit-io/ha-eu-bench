#!/usr/bin/env bash
# What K3s installed by itself, how many copies, and where they run: addons.txt and addons-pods.jsonl.
# Usage: 01-k3s/addons.sh
source "$(dirname "$0")/../lib.sh"

export KUBECONFIG="$STATE/kubeconfig"
out="$(run_dir)"

kubectl get deploy,ds -A -o wide >"$out/addons.txt"
kubectl get nodes -o json | jq -c '[.items[] | {key: .metadata.name, value: .metadata.labels["topology.kubernetes.io/zone"]}] | from_entries' |
  jq -c --slurpfile pods <(kubectl -n kube-system get pods -o json) '. as $zone | $pods[0].items[]
    | {pod: .metadata.name, owner: ([.metadata.ownerReferences[]? | "\(.kind)/\(.name)"][0]), node: .spec.nodeName,
       zone: $zone[.spec.nodeName // ""], phase: .status.phase}' | tee "$out/addons-pods.jsonl"
