#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
[[ ",$(env_value ENABLED_APPS)," == *,drupal,* ]] || exit 0
for ((attempt = 0; attempt < 120; attempt++)); do
  if pg_exec pg_isready -U postgres -d postgres >/dev/null 2>&1; then break; fi
  sleep 2
done
version=$(pg_exec psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres -Atqc 'SHOW server_version_num')
[[ "$version" =~ ^[0-9]+$ ]] && ((version >= 160000)) ||
  { echo "Drupal 11 requires PostgreSQL 16 or newer." >&2; exit 1; }
# The same idempotent initializer also handles previously initialized clusters.
pg_exec sh /docker-entrypoint-initdb.d/10-feuerwehr-users.sh
if [[ "$(env_value DRUPAL_OIDC_ENABLED)" != true ]]; then
  echo "Drupal uses local login; Keycloak OIDC is not enabled."
fi

for ((attempt = 0; attempt < 120; attempt++)); do
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    container=$(swarm_container drupal)
    if [[ -z "$container" ]]; then sleep 2; continue; fi
    exec_command=(docker exec "$container")
  else
    exec_command=("${compose[@]}" exec -T drupal)
  fi
  if "${exec_command[@]}" php -r \
    '$c=stream_context_create(["http"=>["header"=>"Host: ".getenv("DRUPAL_HOST")]]); exit(@file_get_contents("http://127.0.0.1/user/login",false,$c)===false?1:0);' \
    >/dev/null 2>&1; then
    echo "Drupal is ready."
    exit 0
  fi
  sleep 2
done
echo "Drupal did not become ready. Check Drupal logs and rerun scripts/setup-drupal.sh." >&2
exit 1
