#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ASSUME_YES=false
if [[ "${1:-}" == --yes && $# -eq 1 ]]; then
  ASSUME_YES=true
elif (($#)); then
  echo "Usage: $0 [--yes]" >&2
  exit 2
fi
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
echo "Configured image tags:"
grep -E '^[[:space:]]+image:' "$ROOT/compose.yml" || true
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Create backup and update configured images? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || exit 1
fi
"$ROOT/scripts/backup.sh"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
target_postgres_image=$("${compose[@]}" config --format json |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["postgres"]["image"])')
[[ "$target_postgres_image" =~ ^[A-Za-z0-9._:/@-]+$ ]] ||
  { echo "Invalid PostgreSQL image in the resolved Compose configuration." >&2; exit 1; }
"${compose[@]}" pull --ignore-buildable
target_version=$(docker run --rm --entrypoint postgres "$target_postgres_image" --version)
[[ "$target_version" =~ PostgreSQL[^0-9]+([0-9]+)\. ]] ||
  { echo "Could not determine the target PostgreSQL version from: $target_version" >&2; exit 1; }
target_major=${BASH_REMATCH[1]}
if [[ -f "$ROOT/postgres/data/PG_VERSION" ]]; then
  source_major=$(<"$ROOT/postgres/data/PG_VERSION")
  [[ "$source_major" =~ ^[0-9]+$ ]] ||
    { echo "Invalid PostgreSQL PG_VERSION file; refusing to update." >&2; exit 1; }
  if ((target_major != source_major)); then
    if ((target_major < source_major)); then
      echo "PostgreSQL downgrade from $source_major to $target_major is not automatic; refusing to update." >&2
      exit 1
    fi
    bash "$ROOT/scripts/migrate-postgres.sh" "$target_postgres_image" "$source_major" "$target_major"
  fi
fi
if [[ "$DEPLOY_MODE" == swarm ]]; then
  deploy_stack --resolve-image always
else
  "${compose[@]}" up -d
fi
"$ROOT/scripts/healthcheck.sh"
