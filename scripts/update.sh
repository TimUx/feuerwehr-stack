#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
echo "Configured image tags:"
grep -E '^[[:space:]]+image:' "$ROOT/compose.yml" || true
read -r -p "Create backup and update configured images? [y/N] " answer
[[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || exit 1
"$ROOT/scripts/backup.sh"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
if [[ "$DEPLOY_MODE" == swarm ]]; then
  deploy_stack --resolve-image always
else
  "${compose[@]}" pull --ignore-buildable
  "${compose[@]}" up -d
fi
"$ROOT/scripts/healthcheck.sh"
