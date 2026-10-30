#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
archive=${1:-}
[[ -n "$archive" && -f "$archive" ]] || { echo "Usage: $0 BACKUP.tar.gz" >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Run restore as root." >&2; exit 1; }
[[ -f "$ROOT/.env" && -f "$ROOT/compose.yml" ]] || { echo "Run install.sh before restore." >&2; exit 1; }
[[ ! -L "$ROOT/.env" && ! -L "$ROOT/secrets" ]] || { echo "Refusing symlinked configuration or secrets." >&2; exit 1; }
safe_archive() {
  tar -tzf "$1" | awk 'BEGIN{bad=0} /^\// || /(^|\/)\.\.(\/|$)/ {bad=1} END{exit bad}'
}
safe_archive "$archive" || { echo "Archive contains unsafe paths." >&2; exit 1; }

staging=$(mktemp -d)
trap 'rm -rf -- "$staging"' EXIT
tar --no-same-owner -xzf "$archive" -C "$staging"
[[ -f "$staging/files.tar.gz" && ! -L "$staging/files.tar.gz" &&
   -f "$staging/manifest.txt" && ! -L "$staging/manifest.txt" &&
   -d "$staging/database" && ! -L "$staging/database" ]] ||
  { echo "Invalid backup archive." >&2; exit 1; }
for db in keycloak wehrportal synapse drupal; do
  dump="$staging/database/$db.dump"
  [[ ! -e "$dump" || (-f "$dump" && ! -L "$dump") ]] ||
    { echo "Unsafe database dump: $db" >&2; exit 1; }
done
mkdir "$staging/files"
safe_archive "$staging/files.tar.gz" || { echo "Files archive contains unsafe paths." >&2; exit 1; }
tar --same-owner -xzf "$staging/files.tar.gz" -C "$staging/files"
[[ -f "$staging/files/.env" && ! -L "$staging/files/.env" ]] ||
  { echo "Backup .env is missing or is not a regular file." >&2; exit 1; }
[[ -d "$staging/files/secrets" && ! -L "$staging/files/secrets" ]] ||
  { echo "Backup secrets directory is missing or unsafe." >&2; exit 1; }
if find "$staging/files/secrets" -type l -print -quit | grep -q .; then
  echo "Backup contains symlinked secrets." >&2
  exit 1
fi
if find "$staging/files/secrets" -mindepth 1 -maxdepth 1 ! -type f -print -quit | grep -q .; then
  echo "Backup secrets must be regular files." >&2
  exit 1
fi

printf 'This will stop the Compose project and overwrite its configuration and application files.\n'
read -r -p "Type RESTORE to continue: " answer
[[ "$answer" == RESTORE ]] || exit 1
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
if [[ "$DEPLOY_MODE" == swarm ]]; then
  docker stack rm "$STACK_NAME"
  for ((attempt = 0; attempt < 60; attempt++)); do
    [[ -z "$(docker network ls -q --filter "name=^${STACK_NAME}_")" ]] && break
    sleep 2
  done
else
  "${compose[@]}" down
fi
cp -a "$staging/files/." "$ROOT/"
env_tmp=$(mktemp "$ROOT/.env.restore.XXXXXX")
awk -v path="$ROOT" '
  /^STACK_ROOT=/ { print "STACK_ROOT=" path; found=1; next }
  { print }
  END { if (!found) exit 1 }
' "$ROOT/.env" > "$env_tmp" || { rm -f "$env_tmp"; echo "Backup .env has no STACK_ROOT." >&2; exit 1; }
mv -f "$env_tmp" "$ROOT/.env"
chmod 0600 "$ROOT/.env"
chmod 0644 "$ROOT"/secrets/*
[ ! -e "$ROOT/secrets/dns.env" ] || chmod 0600 "$ROOT/secrets/dns.env"
# The restored .env may carry a different deployment mode.
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
if [[ ",$(env_value ENABLED_APPS)," == *,drupal,* ]]; then
  "${compose[@]}" build drupal
fi
if [[ "$DEPLOY_MODE" == swarm ]]; then
  python3 "$ROOT/scripts/generate-swarm-stack.py" --create-bind-dirs "$ROOT"
  python3 - "$ROOT/stack.swarm.yml" "$staging/restore-stack.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    stack = json.load(source)
for name, service in stack["services"].items():
    if name != "postgres":
        service["deploy"]["replicas"] = 0
with open(sys.argv[2], "w") as target:
    json.dump(stack, target)
PY
  docker stack deploy --with-registry-auth -c "$staging/restore-stack.json" "$STACK_NAME"
else
  "${compose[@]}" up -d postgres
fi
for ((attempt = 0; attempt < 60; attempt++)); do
  if pg_exec pg_isready -U postgres -d postgres >/dev/null 2>&1; then break; fi
  sleep 2
done
pg_exec pg_isready -U postgres -d postgres >/dev/null ||
  { echo "PostgreSQL did not become ready." >&2; exit 1; }

apps=$(sed -n 's/^ENABLED_APPS=//p' "$ROOT/.env" | head -n 1)
IFS=',' read -r -a selected_apps <<< "$apps"
for app in "${selected_apps[@]}"; do
  case "$app" in
    keycloak) db=keycloak; role=keycloak ;;
    wehrportal) db=wehrportal; role=wehrportal ;;
    matrix) db=synapse; role=synapse ;;
    drupal) db=drupal; role=drupal ;;
    *) continue ;;
  esac
  if [[ "$db" == drupal && -f "$staging/database/drupal.not-installed" &&
        ! -L "$staging/database/drupal.not-installed" ]]; then
    echo "Restoring uninstalled Drupal state; the next start will install a fresh site."
    pg_exec dropdb -U postgres --if-exists --force drupal
    continue
  fi
  [[ -f "$staging/database/${db}.dump" ]] || { echo "Missing database dump: $db" >&2; exit 1; }
  secret="$ROOT/secrets/${role}_db_password"
  [[ -f "$secret" ]] || { echo "Missing restored secret for $role." >&2; exit 1; }
  pg_exec psql -U postgres -d postgres \
    -v ON_ERROR_STOP=1 \
    --set=db_password="$(cat "$secret")" <<SQL
SELECT format('CREATE ROLE %I LOGIN', '$role')
WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$role') \\gexec
SELECT format('ALTER ROLE %I PASSWORD %L', '$role', :'db_password') \\gexec
SELECT format('CREATE DATABASE %I OWNER %I', '$db', '$role')
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$db') \\gexec
SQL
  if [[ "$db" == drupal || "$db" == wehrportal || "$db" == synapse ]]; then
    # Application migrations must retain ownership of restored tables.
    pg_exec dropdb -U postgres --if-exists --force "$db"
    if [[ "$db" == synapse ]]; then
      pg_exec createdb -U postgres --owner="$role" --template=template0 \
        --encoding=UTF8 --lc-collate=C --lc-ctype=C "$db"
    else
      pg_exec createdb -U postgres --owner="$role" "$db"
    fi
    pg_exec pg_restore -U postgres --role="$role" --exit-on-error --no-owner \
      --dbname "$db" < "$staging/database/$db.dump"
    continue
  fi
  pg_exec pg_restore -U postgres --clean --if-exists --no-owner \
    --dbname "$db" < "$staging/database/${db}.dump"
done
if [[ "$DEPLOY_MODE" == swarm ]]; then
  deploy_stack
  for ((attempt = 0; attempt < 30; attempt++)); do
    "$ROOT/scripts/healthcheck.sh" >/dev/null 2>&1 && break
    sleep 10
  done
else
  "${compose[@]}" up -d
fi
"$ROOT/scripts/setup-apps.sh"
"$ROOT/scripts/healthcheck.sh"
echo "Restore completed. Verify application login, uploaded files, and federation manually."
