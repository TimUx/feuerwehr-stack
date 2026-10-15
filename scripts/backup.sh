#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
mkdir -p "$ROOT/backups"
chmod 0700 "$ROOT/backups"
compose=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml")
[[ ! -f "$ROOT/compose.proxy.yml" ]] || compose+=(-f "$ROOT/compose.proxy.yml")
[[ ! -f "$ROOT/compose.remote.yml" ]] || compose+=(-f "$ROOT/compose.remote.yml")
apps=$(sed -n 's/^ENABLED_APPS=//p' "$ROOT/.env" | head -n 1)
IFS=',' read -r -a selected_apps <<< "$apps"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
staging=$(mktemp -d "$ROOT/backups/.staging.XXXXXX")
trap 'rm -rf -- "$staging"' EXIT
mkdir -m 0700 "$staging/files" "$staging/database"

for app in "${selected_apps[@]}"; do
  case "$app" in
    keycloak) db=keycloak ;;
    openwehr) db=openwehr ;;
    matrix) db=synapse ;;
    *) continue ;;
  esac
  "${compose[@]}" exec -T postgres pg_dump -U postgres --no-owner --format=custom "$db" \
    > "$staging/database/${db}.dump"
  chmod 0600 "$staging/database/${db}.dump"
done
tar -C "$ROOT" --exclude='./postgres/data' --exclude='./backups' --exclude='./logs' \
  -czf "$staging/files.tar.gz" .
cat > "$staging/manifest.txt" <<EOF
created_utc=$stamp
enabled_apps=$apps
database_format=pg_dump-custom
postgres_image=postgres:16.6-alpine
EOF
chmod 0600 "$staging/manifest.txt" "$staging/files.tar.gz"
archive="$ROOT/backups/feuerwehr-$stamp.tar.gz"
tar -C "$staging" -czf "$archive" .
chmod 0600 "$archive"
echo "Backup created: $archive"
