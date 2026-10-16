#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
echo "Configured image tags:"
grep -E '^[[:space:]]+image:' "$ROOT/compose.yml" || true
read -r -p "Create backup and update configured images? [y/N] " answer
[[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || exit 1
"$ROOT/scripts/backup.sh"
compose=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml")
[[ ! -f "$ROOT/compose.proxy.yml" ]] || compose+=(-f "$ROOT/compose.proxy.yml")
[[ ! -f "$ROOT/compose.remote.yml" ]] || compose+=(-f "$ROOT/compose.remote.yml")
"${compose[@]}" pull --ignore-buildable
apps=$(sed -n 's/^ENABLED_APPS=//p' "$ROOT/.env" | head -n 1)
if [[ ",$apps," == *,openwehr,* ]]; then
  "${compose[@]}" build --pull openwehr openwehr-worker
fi
"${compose[@]}" up -d --build
"$ROOT/scripts/healthcheck.sh"
