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
for db in keycloak wehrportal synapse; do
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
compose=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml")
[[ ! -f "$ROOT/compose.proxy.yml" ]] || compose+=(-f "$ROOT/compose.proxy.yml")
[[ ! -f "$ROOT/compose.remote.yml" ]] || compose+=(-f "$ROOT/compose.remote.yml")
"${compose[@]}" down
cp -a "$staging/files/." "$ROOT/"
env_tmp=$(mktemp "$ROOT/.env.restore.XXXXXX")
awk -v path="$ROOT" '
  /^STACK_ROOT=/ { print "STACK_ROOT=" path; found=1; next }
  { print }
  END { if (!found) exit 1 }
' "$ROOT/.env" > "$env_tmp" || { rm -f "$env_tmp"; echo "Backup .env has no STACK_ROOT." >&2; exit 1; }
mv -f "$env_tmp" "$ROOT/.env"
chmod 0600 "$ROOT/.env"
chmod 0600 "$ROOT"/secrets/*
"${compose[@]}" up -d postgres
for ((attempt = 0; attempt < 60; attempt++)); do
  if "${compose[@]}" exec -T postgres pg_isready -U postgres -d postgres >/dev/null 2>&1; then break; fi
  sleep 2
done
"${compose[@]}" exec -T postgres pg_isready -U postgres -d postgres >/dev/null ||
  { echo "PostgreSQL did not become ready." >&2; exit 1; }

apps=$(sed -n 's/^ENABLED_APPS=//p' "$ROOT/.env" | head -n 1)
IFS=',' read -r -a selected_apps <<< "$apps"
for app in "${selected_apps[@]}"; do
  case "$app" in
    keycloak) db=keycloak; role=keycloak ;;
    wehrportal) db=wehrportal; role=wehrportal ;;
    matrix) db=synapse; role=synapse ;;
    *) continue ;;
  esac
  [[ -f "$staging/database/${db}.dump" ]] || { echo "Missing database dump: $db" >&2; exit 1; }
  secret="$ROOT/secrets/${role}_db_password"
  [[ -f "$secret" ]] || { echo "Missing restored secret for $role." >&2; exit 1; }
  "${compose[@]}" exec -T postgres psql -U postgres -d postgres \
    --set=db_password="$(cat "$secret")" <<SQL
SELECT format('ALTER ROLE %I PASSWORD %L', '$role', :'db_password') \\gexec
SQL
  "${compose[@]}" exec -T postgres pg_restore -U postgres --clean --if-exists --no-owner \
    --dbname "$db" < "$staging/database/${db}.dump"
done
"${compose[@]}" up -d
"$ROOT/scripts/healthcheck.sh"
echo "Restore completed. Verify application login, uploaded files, and federation manually."
