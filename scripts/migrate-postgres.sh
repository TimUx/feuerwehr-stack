#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
target_image=${1:-}
source_major=${2:-}
target_major=${3:-}
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run the PostgreSQL migration as root (for example: sudo scripts/update.sh)." >&2; exit 1; }
[[ "$target_image" =~ ^[A-Za-z0-9._:/@-]+$ ]] ||
  { echo "Invalid target PostgreSQL image." >&2; exit 1; }
[[ "$source_major" =~ ^[0-9]+$ && "$target_major" =~ ^[0-9]+$ ]] ||
  { echo "PostgreSQL major versions must be integers." >&2; exit 1; }
((target_major > source_major)) ||
  { echo "Automatic PostgreSQL migration only supports upgrades, not downgrades." >&2; exit 1; }
[[ -f "$ROOT/postgres/data/PG_VERSION" && "$(<"$ROOT/postgres/data/PG_VERSION")" == "$source_major" ]] ||
  { echo "The on-disk PostgreSQL version does not match the detected source version." >&2; exit 1; }
target_version=$(docker run --rm --entrypoint postgres "$target_image" --version)
[[ "$target_version" =~ PostgreSQL[^0-9]+([0-9]+)\. ]] ||
  { echo "Could not determine the target PostgreSQL version from: $target_version" >&2; exit 1; }
[[ "${BASH_REMATCH[1]}" == "$target_major" ]] ||
  { echo "Target image version does not match the requested PostgreSQL major version." >&2; exit 1; }

# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"

data_dir=$ROOT/postgres/data
stamp=$(date -u +%Y%m%dT%H%M%SZ)
old_data_dir=$ROOT/postgres/data.pg${source_major}-$stamp
candidate_data=$ROOT/postgres/data.upgrade-$target_major-$stamp
failed_data=$ROOT/postgres/data.failed-$target_major-$stamp
cluster_dump=$ROOT/backups/postgres-cluster-$source_major-to-$target_major-$stamp.sql.gz
candidate_name=feuerwehr-postgres-upgrade-$stamp
migration_role=fw_migrate_$$
migration_db=fw_migrate_db_$$
old_image=
swapped=false
apps_stopped=false
candidate_started=false
dump_valid=false
success=false
declare -a app_services=()

if [[ "$DEPLOY_MODE" == swarm ]]; then
  source_container=$(swarm_container postgres)
else
  source_container=$("${compose[@]}" ps -q postgres)
fi
[[ -n "$source_container" ]] ||
  { echo "The current PostgreSQL container must be running before a major-version update." >&2; exit 1; }
source_image_id=$(docker inspect --format '{{.Image}}' "$source_container")
old_image=$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$source_image_id" | head -n 1)
[[ "$old_image" =~ ^([A-Za-z0-9._:-]+/)*postgres@sha256:[a-f0-9]{64}$ ]] ||
  { echo "Cannot identify an immutable digest for the current PostgreSQL image; refusing an automatic migration." >&2; exit 1; }
source_version=$(pg_exec psql -X -U postgres -d template1 -Atqc 'SHOW server_version')
[[ "$source_version" =~ ^${source_major}\. ]] ||
  { echo "Running PostgreSQL version does not match the on-disk data version." >&2; exit 1; }
for secret in postgres_superuser_password keycloak_db_password wehrportal_db_password synapse_db_password; do
  [[ -f "$ROOT/secrets/$secret" && ! -L "$ROOT/secrets/$secret" ]] ||
    { echo "Missing or unsafe database secret: $secret." >&2; exit 1; }
done
[[ ! -e "$old_data_dir" && ! -e "$candidate_data" && ! -e "$failed_data" &&
   ! -e "$cluster_dump" && ! -e "$cluster_dump.manifest" ]] ||
  { echo "A PostgreSQL migration path already exists for timestamp $stamp." >&2; exit 1; }
if [[ -n "$(docker ps -aq --filter "name=^/${candidate_name}$")" ]]; then
  echo "Temporary container name already exists: $candidate_name." >&2
  exit 1
fi

stop_postgres() {
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    docker service scale "$STACK_NAME"_postgres=0 >/dev/null
    for ((attempt = 0; attempt < 60; attempt++)); do
      [[ -z "$(docker ps -q --filter "label=com.docker.swarm.service.name=${STACK_NAME}_postgres")" ]] && return 0
      sleep 2
    done
    echo "Timed out waiting for the Swarm PostgreSQL task to stop." >&2
    return 1
  fi
  "${compose[@]}" stop postgres
}

start_postgres() {
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    docker service update --image "$1" --replicas 1 --detach=true "$STACK_NAME"_postgres >/dev/null
  else
    "${compose[@]}" up -d postgres
  fi
}

wait_postgres() {
  local attempt
  for ((attempt = 0; attempt < 60; attempt++)); do
    if pg_exec pg_isready -U postgres -d postgres >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  echo "PostgreSQL did not become ready after the data migration." >&2
  return 1
}

set_postgres_image() {
  local image=$1 env_tmp
  env_tmp=$(mktemp "$ROOT/.env.postgres.XXXXXX")
  awk -v value="$image" '
    BEGIN { found=0 }
    /^POSTGRES_IMAGE=/ { print "POSTGRES_IMAGE=" value; found=1; next }
    { print }
    END { if (!found) print "POSTGRES_IMAGE=" value }
  ' "$ROOT/.env" > "$env_tmp"
  chmod 0600 "$env_tmp"
  mv -f "$env_tmp" "$ROOT/.env"
}

stop_applications() {
  local service
  apps_stopped=true
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    while read -r service replicas; do
      [[ "$service" == "${STACK_NAME}_"* ]] || continue
      case "${service##*_}" in postgres|redis|traefik) continue ;; esac
      [[ "${replicas%%/*}" =~ ^[0-9]+$ ]] && ((replicas%%/* > 0)) || continue
      app_services+=("$service")
      docker service scale "$service=0" >/dev/null
    done < <(docker stack services "$STACK_NAME" --format '{{.Name}} {{.Replicas}}')
    for service in "${app_services[@]}"; do
      for ((attempt = 0; attempt < 60; attempt++)); do
        [[ -z "$(docker ps -q --filter "label=com.docker.swarm.service.name=$service")" ]] && break
        sleep 2
      done
      [[ -z "$(docker ps -q --filter "label=com.docker.swarm.service.name=$service")" ]] ||
        { echo "Timed out waiting for service $service to stop." >&2; return 1; }
    done
  else
    mapfile -t app_services < <("${compose[@]}" ps --services --status running |
      awk '$0 != "postgres" && $0 != "redis" && $0 != "traefik"')
    if ((${#app_services[@]})); then
      "${compose[@]}" stop "${app_services[@]}"
    fi
  fi
}

restart_applications() {
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    local service
    for service in "${app_services[@]}"; do docker service scale "$service=1" >/dev/null || return 1; done
  elif ((${#app_services[@]})); then
    "${compose[@]}" start "${app_services[@]}"
  fi
}

recover() {
  local exit_code=$?
  trap - EXIT
  if [[ "$success" != true ]]; then
    [[ "$candidate_started" != true ]] || docker rm -f "$candidate_name" >/dev/null 2>&1 || true
    if [[ "$swapped" == true ]]; then
      set +e
      rollback_db_status=1
      if stop_postgres; then
        files_status=0
        if [[ -d "$data_dir" && ! -e "$failed_data" ]]; then
          mv "$data_dir" "$failed_data" || files_status=1
        fi
        if [[ -d "$old_data_dir" && ! -e "$data_dir" ]]; then
          mv "$old_data_dir" "$data_dir" || files_status=1
        fi
        if ((files_status == 0)) && [[ -f "$data_dir/PG_VERSION" ]] &&
            [[ "$(<"$data_dir/PG_VERSION")" == "$source_major" ]]; then
          set_postgres_image "$old_image"
          if [[ "$DEPLOY_MODE" == swarm ]]; then
            docker service update --image "$old_image" --replicas 1 --detach=true "$STACK_NAME"_postgres >/dev/null
          else
            "${compose[@]}" up -d postgres
          fi
          wait_postgres
          rollback_db_status=$?
        fi
      fi
      rollback_apps_status=1
      if ((rollback_db_status == 0)); then
        restart_applications
        rollback_apps_status=$?
      fi
      if ((rollback_db_status != 0 || rollback_apps_status != 0)); then
        echo "Automatic rollback did not fully recover the stack. Preserve $cluster_dump, $old_data_dir, and $failed_data for manual recovery." >&2
      fi
    elif [[ "$apps_stopped" == true ]]; then
      set +e
      restart_applications || echo "Could not restart all application services; inspect the stack manually." >&2
    fi
    if [[ "$swapped" != true ]]; then
      rm -rf -- "$candidate_data" "$candidate_data.databases" "$candidate_data.roles" \
        "$candidate_data.restored-databases" "$candidate_data.restored-roles"
    fi
    if [[ "$dump_valid" != true ]]; then rm -f -- "$cluster_dump" "$cluster_dump.manifest"; fi
  else
    docker rm "$candidate_name" >/dev/null 2>&1 || true
    candidate_started=false
    rm -rf -- "$candidate_data"
    rmdir "$ROOT/postgres/data.upgrade-$target_major-$stamp" 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap recover EXIT

echo "Stopping application services for a consistent PostgreSQL cluster dump."
stop_applications
install -d -m 0700 "$ROOT/backups"
pg_exec pg_dumpall -U postgres --quote-all-identifiers |
  gzip -c > "$cluster_dump"
chmod 0600 "$cluster_dump"
gzip -t "$cluster_dump"
  dump_valid=true
printf 'source_major=%s\ntarget_major=%s\nsource_image=%s\ntarget_image=%s\ncreated_utc=%s\n' \
  "$source_major" "$target_major" "$old_image" "$target_image" "$stamp" > "$cluster_dump.manifest"
chmod 0600 "$cluster_dump.manifest"

db_query="SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname"
role_query="SELECT rolname FROM pg_roles WHERE rolcanlogin AND rolname !~ '^pg_' AND rolname <> '$migration_role' ORDER BY rolname"
pg_exec psql -X -U postgres -d template1 -Atqc "$db_query" > "$candidate_data.databases"
pg_exec psql -X -U postgres -d template1 -Atqc "$role_query" > "$candidate_data.roles"
if grep -Fxq "$migration_role" "$candidate_data.roles" ||
   grep -Fxq "$migration_db" "$candidate_data.databases"; then
  echo "Temporary migration database or role already exists in the source cluster; refusing to continue." >&2
  exit 1
fi

install -d -m 0700 "$candidate_data"
candidate_started=true
docker run --detach --name "$candidate_name" \
  --env POSTGRES_USER="$migration_role" \
  --env POSTGRES_DB="$migration_db" \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_superuser_password \
  --env PGDATA=/var/lib/postgresql/data \
  --volume "$candidate_data:/var/lib/postgresql/data" \
  --volume "$ROOT/secrets/postgres_superuser_password:/run/secrets/postgres_superuser_password:ro" \
  "$target_image" >/dev/null
for ((attempt = 0; attempt < 60; attempt++)); do
  if docker exec "$candidate_name" pg_isready -U "$migration_role" -d postgres >/dev/null 2>&1; then break; fi
  sleep 2
done
docker exec "$candidate_name" pg_isready -U "$migration_role" -d postgres >/dev/null ||
  { echo "The temporary PostgreSQL $target_major instance did not become ready." >&2; exit 1; }

gzip -dc "$cluster_dump" |
  docker exec -i "$candidate_name" psql -X -q -U "$migration_role" -d template1 --set=ON_ERROR_STOP=on >/dev/null
docker exec -i "$candidate_name" psql -X -q -U postgres -d template1 --set=ON_ERROR_STOP=on <<SQL
DROP DATABASE $migration_db;
-- PostgreSQL requires the initdb bootstrap superuser; keep it non-login and clear its password.
ALTER ROLE $migration_role NOLOGIN PASSWORD NULL;
SQL

reset_role_password() {
  local role=$1 secret_path=$2 password
  password=$(cat "$secret_path")
  docker exec -i "$candidate_name" psql -X -q -U postgres -d template1 --set=db_password="$password" <<SQL >/dev/null
SELECT format('ALTER ROLE %I PASSWORD %L', '$role', :'db_password')
WHERE EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') \\gexec
SQL
}
reset_role_password postgres "$ROOT/secrets/postgres_superuser_password"
for role in keycloak wehrportal synapse; do
  reset_role_password "$role" "$ROOT/secrets/${role}_db_password"
done

docker exec "$candidate_name" psql -X -U postgres -d template1 -Atqc "$db_query" > "$candidate_data.restored-databases"
docker exec "$candidate_name" psql -X -U postgres -d template1 -Atqc "$role_query" > "$candidate_data.restored-roles"
cmp -s "$candidate_data.databases" "$candidate_data.restored-databases" ||
  { echo "The target PostgreSQL cluster has a different database set; refusing to switch." >&2; exit 1; }
cmp -s "$candidate_data.roles" "$candidate_data.restored-roles" ||
  { echo "The target PostgreSQL cluster has a different login-role set; refusing to switch." >&2; exit 1; }
[[ "$(<"$candidate_data/PG_VERSION")" == "$target_major" ]] ||
  { echo "Temporary data directory has an unexpected PostgreSQL version." >&2; exit 1; }

echo "PostgreSQL dump restored and verified; switching the persistent data directory."
docker stop "$candidate_name" >/dev/null
stop_postgres
mv "$data_dir" "$old_data_dir"
swapped=true
mv "$candidate_data" "$data_dir"
start_postgres "$target_image"
wait_postgres
running_version=$(pg_exec psql -X -U postgres -d template1 -Atqc 'SHOW server_version')
[[ "$running_version" =~ ^${target_major}\. ]] ||
  { echo "PostgreSQL started with an unexpected version: $running_version." >&2; exit 1; }
pg_exec psql -X -U postgres -d template1 -Atqc "$db_query" > "$candidate_data.restored-databases"
cmp -s "$candidate_data.databases" "$candidate_data.restored-databases" ||
  { echo "The live PostgreSQL database set differs after the switch." >&2; exit 1; }
swapped=false
success=true
rm -rf -- "$candidate_data.databases" "$candidate_data.roles" "$candidate_data.restored-databases" \
  "$candidate_data.restored-roles"
echo "PostgreSQL $source_major -> $target_major migration completed. Previous data retained at $old_data_dir."
