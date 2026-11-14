#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
ASSUME_YES=false
LOCAL_FILES=false
UPDATE_REF=
release_ref=false
usage() {
  echo "Usage: $0 [--yes] [--local-files] [--ref TAG_OR_BRANCH]" >&2
  exit 2
}
original_args=("$@")
while (($#)); do
  case "$1" in
    --yes) ASSUME_YES=true ;;
    --local-files) LOCAL_FILES=true ;;
    --ref) (($# >= 2)) || usage; UPDATE_REF=$2; shift ;;
    *) usage ;;
  esac
  shift
done
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env." >&2; exit 1; }
[[ ! -L "$ROOT/scripts" && ! -L "$ROOT/compose.yml" ]] ||
  { echo "Refusing to update through symlinked stack paths." >&2; exit 1; }

if [[ "$LOCAL_FILES" != true ]]; then
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to check for updated stack scripts." >&2
  exit 1
fi

repository=TimUx/feuerwehr-stack
update_tmp=$(mktemp -d "$ROOT/.update-scripts.XXXXXX")
trap 'rm -rf -- "${update_tmp:?}"' EXIT
if [[ -z "$UPDATE_REF" ]]; then
  # Follow published releases, not the development branch: only a deliberately released
  # state of the stack reaches an installation.
  status=$(curl --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 30 \
    --output "$update_tmp/release.json" --write-out '%{http_code}' \
    "https://api.github.com/repos/$repository/releases/latest")
  case "$status" in
    200)
      UPDATE_REF=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["tag_name"])' \
        "$update_tmp/release.json") ||
        { echo "Could not read the latest release of $repository." >&2; exit 1; }
      release_ref=true
      ;;
    404)
      echo "WARN: $repository has no published release yet; updating from the main branch." >&2
      UPDATE_REF=main
      ;;
    *)
      echo "Could not determine the latest release of $repository (HTTP $status)." >&2
      echo "Retry later or choose a version explicitly with --ref <tag>." >&2
      exit 1
      ;;
  esac
fi
[[ "$UPDATE_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ && "$UPDATE_REF" != *..* ]] ||
  { echo "Invalid update reference: $UPDATE_REF" >&2; exit 1; }
installed_ref=$(cat "$ROOT/.stack-version" 2>/dev/null || true)
echo "Stack files: installed ${installed_ref:-unknown}, updating to $UPDATE_REF."
repo_raw_url=https://raw.githubusercontent.com/$repository/$UPDATE_REF
# The release workflow publishes SHA256SUMS once, when a release is created. Unlike the tag it does
# not follow later changes, so a moved tag or an altered download is noticed here.
checksums=
status=$(curl --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 30 \
  --output "$update_tmp/SHA256SUMS" --write-out '%{http_code}' \
  "https://github.com/$repository/releases/download/$UPDATE_REF/SHA256SUMS")
case "$status" in
  200) checksums=$update_tmp/SHA256SUMS ;;
  404)
    if [[ "$release_ref" == true ]]; then
      echo "Release $UPDATE_REF has no SHA256SUMS file (yet); refusing to install unverified files." >&2
      echo "Retry in a few minutes or choose a version explicitly with --ref <tag>." >&2
      exit 1
    fi
    echo "WARN: no published checksums for $UPDATE_REF; the downloaded files are not verified." >&2
    ;;
  *)
    echo "Could not download the checksums of $UPDATE_REF (HTTP $status)." >&2
    exit 1
    ;;
esac
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
  scripts/backup-timer.sh
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
  if [[ -n "$checksums" ]]; then
    expected_sum=$(awk -v file="$file" '$2 == file { print $1; exit }' "$checksums")
    actual_sum=$(sha256sum "$staged_file")
    [[ "$expected_sum" =~ ^[0-9a-f]{64}$ && "${actual_sum%% *}" == "$expected_sum" ]] ||
      { echo "Checksum mismatch for $file in $UPDATE_REF; nothing was installed." >&2; exit 1; }
  fi
  case "$file" in
    *.sh) bash -n "$staged_file" ;;
    *.py) python3 -c 'import pathlib, sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' "$staged_file" ;;
  esac
done
[[ -z "$checksums" ]] || echo "Verified ${#managed_files[@]} files against the published checksums of $UPDATE_REF."

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
  rm -rf -- "${update_tmp:?}"
  trap - EXIT
  exec bash "$ROOT/scripts/update.sh" "${original_args[@]}"
fi
printf '%s\n' "$UPDATE_REF" > "$ROOT/.stack-version"
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

# A floating PostgreSQL tag would start a major-version migration whenever upstream releases one.
# Pin it to the major version of the existing cluster; upgrades then need an explicit .env change.
if [[ -f "$ROOT/postgres/data/PG_VERSION" ]] && grep -qx 'POSTGRES_IMAGE=postgres:latest' "$ROOT/.env"; then
  [[ ! -L "$ROOT/.env" ]] || { echo "Refusing to edit a symlinked .env." >&2; exit 1; }
  installed_major=$(<"$ROOT/postgres/data/PG_VERSION")
  [[ "$installed_major" =~ ^[0-9]+$ ]] ||
    { echo "Invalid PostgreSQL PG_VERSION file; refusing to update." >&2; exit 1; }
  sed -i "s/^POSTGRES_IMAGE=postgres:latest\$/POSTGRES_IMAGE=postgres:$installed_major/" "$ROOT/.env"
  echo "Pinned POSTGRES_IMAGE in .env to postgres:$installed_major (was postgres:latest)."
fi

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
