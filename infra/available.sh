#!/usr/bin/env bash
# Can this machine type be ordered in every zone we use? Run it before `tofu apply`.
# Usage: infra/available.sh hetzner cpx22 | scaleway BASIC3-X2C-4G | ovh c3-4
# SCW_ZONES and OVH_REGION choose other zones than Milan.
set -euo pipefail

source "$(dirname "$0")/../env.sh"
provider="$1"
type="$2"

hetzner() {
  curl -sf -H "Authorization: Bearer $HCLOUD_TOKEN" "https://api.hetzner.cloud/v1/server_types?name=$type" |
    jq -r '.server_types[0].locations[] | select(.name == ("fsn1", "nbg1", "hel1")) |
      "\(.name)\t\(if .available then "available" else "not available" end)\(if .deprecation then " (deprecated)" else "" end)"'
}

scaleway() {
  local zone page reply state found
  for zone in ${SCW_ZONES:-it-mil-1 it-mil-2 it-mil-3}; do
    state="unknown type"
    for page in 1 2 3 4 5; do
      reply="$(curl -sf -H "X-Auth-Token: $SCW_SECRET_KEY" \
        "https://api.scaleway.com/instance/v1/zones/$zone/products/servers/availability?per_page=100&page=$page")"
      [[ "$(jq '.servers | length' <<<"$reply")" == 0 ]] && break
      found="$(jq -r --arg t "$type" '.servers[$t].availability // empty' <<<"$reply")"
      [[ -n "$found" ]] && state="$found" && break
    done
    printf '%s\t%s\n' "$zone" "$state"
  done
}

ovh() {
  local region="${OVH_REGION:-EU-SOUTH-MIL}" headers body token nova
  headers="$(mktemp)"
  body="$(jq -n '{auth: {
    identity: {methods: ["password"], password: {user: {
      name: env.OS_USERNAME, password: env.OS_PASSWORD, domain: {name: (env.OS_USER_DOMAIN_NAME // "Default")}}}},
    scope: {project: {id: env.OS_PROJECT_ID, domain: {name: (env.OS_PROJECT_DOMAIN_NAME // "Default")}}}}}' |
    curl -sf -D "$headers" -H 'Content-Type: application/json' -d @- "${OS_AUTH_URL%/}/auth/tokens")"
  token="$(sed -n 's/^x-subject-token: *//ip' "$headers" | tr -d '\r')"
  rm -f "$headers"
  nova="$(jq -r --arg r "$region" '.token.catalog[] | select(.type == "compute") |
    .endpoints[] | select(.region == $r and .interface == "public") | .url' <<<"$body")"

  curl -sf -H "X-Auth-Token: $token" "$nova/flavors/detail" |
    jq -r --arg t "$type" --arg r "$region" \
      'if any(.flavors[]; .name == $t) then "\($r)\t\($t) offered" else "\($r)\t\($t) not offered" end'
  curl -sf -H "X-Auth-Token: $token" "$nova/os-availability-zone" |
    jq -r '.availabilityZoneInfo[] | "\(.zoneName)\t\(if .zoneState.available then "zone up" else "zone down" end)"'
  echo "OVH publishes no stock per zone: an order can still fail in one of them." >&2
}

"$provider"
