#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ASSUME_YES=false
LOCAL_FILES=false
for option in "$@"; do
  case "$option" in
    --yes) ASSUME_YES=true ;;
    --local-files) LOCAL_FILES=true ;;
    *) echo "Usage: $0 [--yes] [--local-files]" >&2; exit 2 ;;
  esac
done
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
[[ ! -L "$ROOT/scripts" && ! -L "$ROOT/compose.yml" ]] ||
  { echo "Refusing to update through symlinked stack paths." >&2; exit 1; }

if [[ "$LOCAL_FILES" != true ]]; then
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
  scripts/synapse-entrypoint.sh
  scripts/setup-synapse.sh
  scripts/setup-wehrportal-office.sh
  scripts/configure-wehrportal-office.php
  scripts/installation-summary.sh
  scripts/backup.sh
  scripts/restore.sh
  scripts/migrate-postgres.sh
  scripts/healthcheck.sh
  scripts/validate.sh
  scripts/uninstall.sh
  scripts/lib.sh
  scripts/generate-swarm-stack.py
  scripts/setup-drupal.sh
  scripts/setup-apps.sh
  scripts/setup-wehrportal.sh
  scripts/configure-wehrportal-oidc.php
  scripts/configure-keycloak.py
  drupal/Dockerfile
  drupal/.dockerignore
  drupal/composer.json
  drupal/composer.lock
  drupal/settings.php
  drupal/configure.php
  drupal/entrypoint.sh
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
  mkdir -p -- "$(dirname -- "$ROOT/$file")"
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
fi

for name in drupal_db_password drupal_hash_salt drupal_admin_password drupal_oidc_client_secret wehrportal_oidc_client_secret synapse_oidc_client_secret; do
  path="$ROOT/secrets/$name"
  [[ ! -L "$path" ]] || { echo "Refusing symlinked application secret: $name" >&2; exit 1; }
  if [[ ! -e "$path" ]]; then
    (umask 077; openssl rand -hex 32 > "$path")
    # Compose bind-mounted secrets must be readable by the container's service user.
    chmod 0644 "$path"
  fi
  [[ -f "$path" && -s "$path" ]] || { echo "Missing or empty application secret: $name" >&2; exit 1; }
done

echo "Configured image tags:"
grep -E '^[[:space:]]+image:' "$ROOT/compose.yml" || true
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Create backup and update configured images? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || exit 1
fi
if [[ -f "$ROOT/postgres/data/PG_VERSION" ]]; then
  "$ROOT/scripts/backup.sh"
else
  echo "No PostgreSQL cluster exists yet; starting a fresh installation without a pre-install backup."
fi
# Regenerate proxy labels/routes so changes to generate-proxy-config.sh reach existing installs.
proxy_value() { sed -n "s/^$1=//p" "$ROOT/.env" | head -n 1; }
proxy_mode=$(proxy_value PROXY_MODE)
if [[ -n "$proxy_mode" ]]; then
  if [[ "$proxy_mode" == own || "$proxy_mode" == same-host ]]; then
    proxy_args=("$proxy_mode" "$(proxy_value ENABLE_PROXY_ROUTES)" "$(proxy_value TRAEFIK_CERT_RESOLVER)"
      "$(proxy_value TRAEFIK_NETWORK)" "$(proxy_value ACME_CHALLENGE)" "$(proxy_value ACME_DNS_PROVIDER)")
  else
    proxy_args=(remote "$(proxy_value ENABLE_PROXY_ROUTES)" "" "" http "")
  fi
  "$ROOT/scripts/generate-proxy-config.sh" "$ROOT" "$(proxy_value ENABLED_APPS)" "${proxy_args[@]}"
fi
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
target_postgres_image=$("${compose[@]}" config --format json |
  python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["postgres"]["image"])')
[[ "$target_postgres_image" =~ ^[A-Za-z0-9._:/@-]+$ ]] ||
  { echo "Invalid PostgreSQL image in the resolved Compose configuration." >&2; exit 1; }
"${compose[@]}" pull --ignore-buildable
if [[ ",$(env_value ENABLED_APPS)," == *,drupal,* ]]; then
  "${compose[@]}" build drupal
fi
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
if [[ ",$(env_value COMPOSE_PROFILES)," == *,onlyoffice,* ]]; then
  # A persisted /var/lib/onlyoffice from an older image mixes versions (404 on web-apps assets).
  oo_image=$("${compose[@]}" config --format json |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["services"]["onlyoffice"]["image"])')
  oo_id=$(docker image inspect --format '{{.Id}}' "$oo_image")
  oo_root=$(env_value STACK_ROOT)
  oo_root=${oo_root:-$ROOT}
  oo_marker="$oo_root/onlyoffice/.image-id"
  if [[ -d "$oo_root/onlyoffice/lib" && "$(cat "$oo_marker" 2>/dev/null || true)" != "$oo_id" ]]; then
    echo "ONLYOFFICE image changed; resetting generated files in onlyoffice/lib (keeping App_Data)."
    if [[ "$DEPLOY_MODE" == swarm ]]; then
      docker service scale "${STACK_NAME}_onlyoffice=0" >/dev/null 2>&1 || true
    else
      "${compose[@]}" stop onlyoffice
    fi
    docker run --rm --entrypoint /bin/bash -v "$oo_root/onlyoffice/lib:/lib-reset" "$oo_image" -c \
      'find /lib-reset -mindepth 1 -maxdepth 2 ! -path "*/App_Data" ! -path "*/App_Data/*" -not -path /lib-reset/documentserver -exec rm -rf -- {} + 2>/dev/null; true'
  fi
  printf '%s\n' "$oo_id" >"$oo_marker"
fi
if [[ "$DEPLOY_MODE" == swarm ]]; then
  deploy_stack --resolve-image always
else
  "${compose[@]}" up -d
fi
"$ROOT/scripts/setup-apps.sh"
"$ROOT/scripts/healthcheck.sh"
