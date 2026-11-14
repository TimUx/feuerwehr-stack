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
printf '%s\n' "$url" >> "$MOCK_CURL_LOG"
if [[ "$url" == https://api.github.com/repos/TimUx/feuerwehr-stack/releases/latest ]]; then
  # MOCK_RELEASE: a tag name, "none" (no release published) or "error" (API unavailable).
  case "$MOCK_RELEASE" in
    none) printf '{"message":"Not Found"}' > "$output"; printf 404 ;;
    error) printf '{}' > "$output"; printf 503 ;;
    *) printf '{"tag_name":"%s"}' "$MOCK_RELEASE" > "$output"; printf 200 ;;
  esac
  exit 0
fi
if [[ "$url" == https://github.com/TimUx/feuerwehr-stack/releases/download/"$MOCK_EXPECTED_REF"/SHA256SUMS ]]; then
  # MOCK_CHECKSUMS: "valid" (default), "tampered", "missing" (no such asset) or "error".
  case "${MOCK_CHECKSUMS:-valid}" in
    missing) printf 'Not Found' > "$output"; printf 404; exit 0 ;;
    error) : > "$output"; printf 503; exit 0 ;;
  esac
  # Same format as .github/workflows/release.yml: sha256sum over repository-relative paths.
  (cd "$MOCK_REPOSITORY" && find . -type f -printf '%P\0' | xargs -0 sha256sum) > "$output"
  [[ "${MOCK_CHECKSUMS:-valid}" != tampered ]] ||
    sed -i -E 's/^[0-9a-f]{64}(  compose\.yml)$/'"$(printf 'x' | sha256sum | cut -d' ' -f1)"'\1/' "$output"
  printf 200
  exit 0
fi
file=${url#https://raw.githubusercontent.com/TimUx/feuerwehr-stack/"$MOCK_EXPECTED_REF"/}
[[ "$file" != "$url" ]] || { echo "Unexpected download URL: $url" >&2; exit 1; }
cp "$MOCK_REPOSITORY/$file" "$output"
EOF
chmod +x "$tmp/bin/curl"
export MOCK_CURL_LOG="$tmp/curl.log"

# An unavailable release API must stop the update instead of silently falling back.
if MOCK_RELEASE=error MOCK_EXPECTED_REF=main MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
    bash "$installation/scripts/update.sh" --yes > "$tmp/output" 2>&1; then
  echo "Update continued without a release answer." >&2
  exit 1
fi
grep -q 'HTTP 503' "$tmp/output"
[[ ! -e "$installation/restarted" && ! -e "$installation/.stack-version" ]]
if MOCK_RELEASE='v1.0.0/../../main' MOCK_EXPECTED_REF=main MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
    bash "$installation/scripts/update.sh" --yes > "$tmp/output" 2>&1; then
  echo "An unsafe release tag was accepted." >&2
  exit 1
fi
grep -q 'Invalid update reference' "$tmp/output"

# A release must come with checksums, and every downloaded file must match them.
for checksums in missing error tampered; do
  if MOCK_RELEASE=v1.2.3 MOCK_EXPECTED_REF=v1.2.3 MOCK_CHECKSUMS=$checksums MOCK_REPOSITORY="$repository" \
      PATH="$tmp/bin:$PATH" bash "$installation/scripts/update.sh" --yes > "$tmp/output" 2>&1; then
    echo "Update continued with $checksums checksums." >&2
    exit 1
  fi
  [[ ! -e "$installation/restarted" && ! -e "$installation/scripts/installation-summary.sh" ]]
done
grep -q 'Checksum mismatch for compose.yml' "$tmp/output"

# The latest published release, not the development branch, is the default source.
MOCK_RELEASE=v1.2.3 MOCK_EXPECTED_REF=v1.2.3 MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
  bash "$installation/scripts/update.sh" --yes > "$tmp/output"
grep -q 'updating to v1.2.3' "$tmp/output"
grep -q 'against the published checksums of v1.2.3' "$tmp/output"
grep -q '/v1.2.3/compose.yml$' "$MOCK_CURL_LOG"
if grep -q '/main/' "$MOCK_CURL_LOG"; then exit 1; fi

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
[[ ! -e "$installation/.stack-version" ]]

# Without any published release the update keeps working from main, visibly.
cp "$installation"/scripts/* "$repository/scripts/"
rm "$installation/setup-apps-called"
MOCK_RELEASE=none MOCK_EXPECTED_REF=main MOCK_CHECKSUMS=missing MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
  bash "$installation/scripts/update.sh" --yes > "$tmp/output" 2> "$tmp/errors"
grep -q 'no published release yet' "$tmp/errors"
grep -q 'no published checksums for main' "$tmp/errors"
[[ "$(<"$installation/.stack-version")" == main && -f "$installation/setup-apps-called" ]]

# An explicit reference is used as given and never asks the release API.
: > "$MOCK_CURL_LOG"
MOCK_RELEASE=error MOCK_EXPECTED_REF=v9.9.9 MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
  bash "$installation/scripts/update.sh" --yes --ref v9.9.9 > "$tmp/output"
grep -q 'installed main, updating to v9.9.9' "$tmp/output"
[[ "$(<"$installation/.stack-version")" == v9.9.9 ]]
if grep -q 'api.github.com' "$MOCK_CURL_LOG"; then exit 1; fi
if bash "$installation/scripts/update.sh" --ref > /dev/null 2>&1; then exit 1; fi

# A floating PostgreSQL tag is pinned to the major version of the existing cluster.
mkdir -p "$installation/postgres/data"
printf '18\n' > "$installation/postgres/data/PG_VERSION"
printf 'DEPLOY_MODE=compose\nPOSTGRES_IMAGE=postgres:latest\nENABLED_APPS=\n' > "$installation/.env"
chmod 0600 "$installation/.env"
printf '#!/usr/bin/env bash\ntouch "%s/backup-called"\n' "$installation" > "$installation/scripts/backup.sh"
PATH="$tmp/bin:$PATH" bash "$installation/scripts/update.sh" --yes --local-files > "$tmp/output"
grep -qx 'POSTGRES_IMAGE=postgres:18' "$installation/.env"
grep -qx 'DEPLOY_MODE=compose' "$installation/.env"
[[ "$(stat -c %a "$installation/.env")" == 600 && -f "$installation/backup-called" ]]
grep -q 'Pinned POSTGRES_IMAGE' "$tmp/output"
PATH="$tmp/bin:$PATH" bash "$installation/scripts/update.sh" --yes --local-files > "$tmp/output"
if grep -q 'Pinned POSTGRES_IMAGE' "$tmp/output"; then exit 1; fi
echo "Release selection, checksum verification, PostgreSQL pinning, update refresh, self-restart, and local-file first-start checks passed."
