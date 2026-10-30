# Load .env and fill in the project ids the credentials already imply.
# Usage: source env.sh

_env="$(dirname "${BASH_SOURCE[0]:-$0}")/.env"
set -a
# shellcheck source=/dev/null
[[ -f "$_env" ]] && source "$_env"
set +a
unset _env

if [[ -n "${SCW_ACCESS_KEY:-}" && -z "${SCW_DEFAULT_PROJECT_ID:-}" ]]; then
  SCW_DEFAULT_PROJECT_ID="$(curl -sf -H "X-Auth-Token: $SCW_SECRET_KEY" \
    "https://api.scaleway.com/iam/v1alpha1/api-keys/$SCW_ACCESS_KEY" | jq -r '.default_project_id // empty')"
  export SCW_DEFAULT_PROJECT_ID
fi

if [[ -n "${OS_USERNAME:-}" ]]; then
  export OS_AUTH_URL="${OS_AUTH_URL:-https://auth.cloud.ovh.net/v3}"
  export OS_USER_DOMAIN_NAME="${OS_USER_DOMAIN_NAME:-Default}"
fi

if [[ -n "${OS_USERNAME:-}" && -z "${OS_PROJECT_ID:-}" ]]; then
  _token="$(jq -n '{auth: {identity: {methods: ["password"], password: {user: {
      name: env.OS_USERNAME, password: env.OS_PASSWORD, domain: {name: (env.OS_USER_DOMAIN_NAME // "Default")}}}}}}' |
    curl -sf -D - -o /dev/null -H 'Content-Type: application/json' -d @- "${OS_AUTH_URL%/}/auth/tokens" |
    sed -n 's/^x-subject-token: *//ip' | tr -d '\r')"
  OS_PROJECT_ID="$(curl -sf -H "X-Auth-Token: $_token" "${OS_AUTH_URL%/}/auth/projects" |
    jq -r '[.projects[] | select(.enabled)] | if length == 1 then .[0].id else empty end')"
  unset _token
  export OS_PROJECT_ID
fi
