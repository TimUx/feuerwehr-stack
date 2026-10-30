#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repository="$tmp/repository"
installation="$tmp/installation"
mkdir -p "$repository/scripts" "$installation/scripts" "$repository/drupal" "$tmp/bin"
cp "$ROOT/drupal/"{Dockerfile,.dockerignore,composer.json,composer.lock,settings.php,configure.php,entrypoint.sh} "$repository/drupal/"
cp "$ROOT/compose.yml" "$repository/compose.yml"
cp "$ROOT/compose.yml" "$installation/compose.yml"
cp "$ROOT"/scripts/* "$repository/scripts/"
cp "$ROOT"/scripts/* "$installation/scripts/"
rm "$installation/scripts/setup-wehrportal-office.sh" "$installation/scripts/configure-wehrportal-office.php" \
  "$installation/scripts/installation-summary.sh"
: > "$installation/.env"

cat > "$repository/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
printf '%s\n' "$*" > "$ROOT/restarted"
EOF
printf '#!/usr/bin/env bash\nprintf updated-backup\n' > "$repository/scripts/backup.sh"

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=
url=
while (($#)); do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
file=${url#*/main/}
cp "$MOCK_REPOSITORY/$file" "$output"
EOF
chmod +x "$tmp/bin/curl"

MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
  bash "$installation/scripts/update.sh" --yes > "$tmp/output"

[[ "$(<"$installation/restarted")" == --yes ]]
[[ "$(<"$installation/scripts/backup.sh")" == $'#!/usr/bin/env bash\nprintf updated-backup' ]]
grep -q 'restarting it before continuing' "$tmp/output"
cmp "$repository/scripts/setup-wehrportal-office.sh" "$installation/scripts/setup-wehrportal-office.sh"
cmp "$repository/scripts/configure-wehrportal-office.php" "$installation/scripts/configure-wehrportal-office.php"
cmp "$repository/scripts/installation-summary.sh" "$installation/scripts/installation-summary.sh"

cp "$ROOT/scripts/update.sh" "$installation/scripts/update.sh"
rm "$installation/restarted"
mkdir "$installation/secrets"
cat > "$installation/scripts/lib.sh" <<'EOF'
compose=(docker compose)
DEPLOY_MODE=compose
env_value() { :; }
EOF
printf '#!/usr/bin/env bash\nexit 42\n' > "$installation/scripts/backup.sh"
for script in setup-apps healthcheck; do
  printf '#!/usr/bin/env bash\ntouch "%s/%s-called"\n' "$installation" "$script" > "$installation/scripts/$script.sh"
done
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$*" in
  'compose config --format json') printf '{"services":{"postgres":{"image":"postgres:18"}}}' ;;
  'run --rm --entrypoint postgres postgres:18 --version') printf 'postgres (PostgreSQL) 18.0\n' ;;
  'compose pull --ignore-buildable'|'compose up -d') ;;
  *) echo "Unexpected Docker invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/docker"
PATH="$tmp/bin:$PATH" bash "$installation/scripts/update.sh" --yes --local-files > "$tmp/local-output"
[[ ! -e "$installation/restarted" ]]
[[ -f "$installation/setup-apps-called" && -f "$installation/healthcheck-called" ]]
grep -q 'fresh installation without a pre-install backup' "$tmp/local-output"
echo "Update refresh, self-restart, and local-file first-start checks passed."
