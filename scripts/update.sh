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
[[ ! -L "$ROOT/scripts" && ! -L "$ROOT/compose.yml" ]] ||
  { echo "Refusing to update through symlinked stack paths." >&2; exit 1; }

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to check for updated stack scripts." >&2
  exit 1
fi

repo_raw_url=https://raw.githubusercontent.com/TimUx/feuerwehr-stack/main
update_tmp=$(mktemp -d "$ROOT/.update-scripts.XXXXXX")
trap 'rm -rf -- "$update_tmp"' EXIT
managed_files=(
  compose.yml
  scripts/postgres-init.sh
  scripts/keycloak-entrypoint.sh
  scripts/wehrportal-entrypoint.sh
  scripts/onlyoffice-entrypoint.sh
  scripts/generate-proxy-config.sh
  scripts/configure-synapse.py
  scripts/backup.sh
  scripts/restore.sh
  scripts/migrate-postgres.sh
  scripts/healthcheck.sh
  scripts/validate.sh
  scripts/uninstall.sh
  scripts/lib.sh
  scripts/generate-swarm-stack.py
  scripts/update.sh
)
update_script_changed=false
for file in "${managed_files[@]}"; do
  staged_file="$update_tmp/$file"
  mkdir -p -- "$(dirname -- "$staged_file")"
  curl --fail --location --silent --show-error --retry 2 --connect-timeout 10 --max-time 120 \
    --output "$staged_file" "$repo_raw_url/$file"
  [[ -s "$staged_file" ]] || { echo "Downloaded an empty file for $file." >&2; exit 1; }
  case "$file" in
    *.sh) bash -n "$staged_file" ;;
    *.py) python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' "$staged_file" ;;
  esac
done

for file in "${managed_files[@]}"; do
  staged_file="$update_tmp/$file"
  if [[ -e "$ROOT/$file" ]] && cmp -s "$staged_file" "$ROOT/$file"; then
    continue
  fi
  mode=0644
  [[ "$file" != *.sh ]] || mode=0755
  chmod "$mode" "$staged_file"
  mv -f -- "$staged_file" "$ROOT/$file"
  echo "Updated $file from the repository."
  [[ "$file" != scripts/update.sh ]] || update_script_changed=true
done

if [[ "$update_script_changed" == true ]]; then
  echo "The update script was updated; restarting it before continuing."
  rm -rf -- "$update_tmp"
  trap - EXIT
  exec bash "$ROOT/scripts/update.sh" "$@"
fi

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
