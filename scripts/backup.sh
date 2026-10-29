#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
mkdir -p "$ROOT/backups"
chmod 0700 "$ROOT/backups"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
if [[ "$DEPLOY_MODE" == swarm ]]; then
  postgres_container=$(swarm_container postgres)
else
  postgres_container=$("${compose[@]}" ps -q postgres)
fi
[[ -n "$postgres_container" ]] || { echo "PostgreSQL container is not running." >&2; exit 1; }
postgres_image=$(docker inspect --format '{{.Config.Image}}' "$postgres_container")
postgres_version=$(pg_exec psql -X -U postgres -d postgres -Atqc 'SHOW server_version')
apps=$(sed -n 's/^ENABLED_APPS=//p' "$ROOT/.env" | head -n 1)
IFS=',' read -r -a selected_apps <<< "$apps"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
staging=$(mktemp -d "$ROOT/backups/.staging.XXXXXX")
stopped=()
restart_apps() {
  ((${#stopped[@]})) || return 0
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    local service
    for service in "${stopped[@]}"; do
      docker service scale "$service=1" >/dev/null ||
        echo "WARN: could not restart service $service." >&2
    done
  elif ! "${compose[@]}" start "${stopped[@]}" >/dev/null; then
    echo "WARN: could not restart every stopped application container." >&2
  fi
}
cleanup() {
  restart_apps
  rm -rf -- "$staging"
}
trap cleanup EXIT
mkdir -m 0700 "$staging/files" "$staging/database"

if [[ "$DEPLOY_MODE" == swarm ]]; then
  mapfile -t running_services < <(docker stack services "$STACK_NAME" \
    --format '{{.Name}} {{.Replicas}}' | awk '$2 !~ /^0\// {print $1}')
  prefix=${STACK_NAME}_
else
  mapfile -t running_services < <("${compose[@]}" ps --services --status running)
  prefix=
fi
for service in "${running_services[@]}"; do
  case "${service#"$prefix"}" in postgres|redis|traefik) continue ;; esac
  stopped+=("$service")
done
if ((${#stopped[@]})); then
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    for service in "${stopped[@]}"; do docker service scale "$service=0" >/dev/null; done
  else
    "${compose[@]}" stop "${stopped[@]}"
  fi
fi

for app in "${selected_apps[@]}"; do
  case "$app" in
    keycloak) db=keycloak ;;
    wehrportal) db=wehrportal ;;
    matrix) db=synapse ;;
    *) continue ;;
  esac
  pg_exec pg_dump -U postgres --no-owner --format=custom "$db" \
    > "$staging/database/${db}.dump"
  chmod 0600 "$staging/database/${db}.dump"
done
tar -C "$ROOT" --exclude='./postgres/data' --exclude='./backups' --exclude='./logs' \
  -czf "$staging/files.tar.gz" .
cat > "$staging/manifest.txt" <<EOF
created_utc=$stamp
enabled_apps=$apps
database_format=pg_dump-custom
postgres_image=$postgres_image
postgres_version=$postgres_version
EOF
chmod 0600 "$staging/manifest.txt" "$staging/files.tar.gz"
archive="$ROOT/backups/feuerwehr-$stamp.tar.gz"
tar -C "$staging" -czf "$archive" .
chmod 0600 "$archive"
echo "Backup created: $archive"
