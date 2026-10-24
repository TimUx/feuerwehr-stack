#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/remote.env" <<'EOF'
PROXY_MODE=remote
VPN_BACKEND_IP=10.20.0.5
ENABLED_APPS=keycloak,matrix
BASE_DOMAIN=example.org
ACME_EMAIL=admin@example.org
MATRIX_SERVER_NAME=matrix.example.org
EOF
output=$("$ROOT/install.sh" --config "$tmp/remote.env" --path "$tmp/stack" --dry-run)
grep -q 'Dry run complete' <<< "$output"
grep -q 'DNS Keycloak (login): login.example.org' <<< "$output"
grep -q 'DNS Matrix Server: matrix.example.org' <<< "$output"
grep -q 'DNS Matrix Web-Messenger: messenger.example.org' <<< "$output"
if grep -q 'DNS WehrPortal' <<< "$output"; then
  echo "Installer showed a DNS record for an unselected application." >&2
  exit 1
fi
[[ ! -e "$tmp/stack" ]]
if grep -Eq 'secret|password|token' <<< "$output"; then
  echo "Dry-run exposed secret-related output." >&2
  exit 1
fi

mkdir "$tmp/nonempty"
touch "$tmp/nonempty/keep"
if "$ROOT/install.sh" --config "$tmp/remote.env" --path "$tmp/nonempty" --dry-run >/dev/null 2>&1; then
  echo "Installer accepted an unrelated non-empty path." >&2
  exit 1
fi
[[ -f "$tmp/nonempty/keep" ]]

mkdir -p "$tmp/legacy"
cat > "$tmp/legacy/.env" <<'EOF'
ENABLED_APPS=keycloak,openwehr
OPENWEHR_HOST=portal.example.org
EOF
if "$ROOT/install.sh" --config "$tmp/remote.env" --path "$tmp/legacy" --dry-run >/dev/null 2>&1; then
  echo "Installer accepted an in-place OpenWehr-to-WehrPortal replacement." >&2
  exit 1
fi
grep -q 'ENABLED_APPS=keycloak,openwehr' "$tmp/legacy/.env"

cat > "$tmp/wehrportal.env" <<'EOF'
PROXY_MODE=remote
VPN_BACKEND_IP=10.20.0.5
ENABLED_APPS=wehrportal
BASE_DOMAIN=example.org
MAIL_HOST=smtp.example.org
MAIL_FROM_ADDRESS=admin@example.org
WEHRPORTAL_ADMIN_EMAILS=admin@example.org
EOF
mkdir -p "$tmp/existing-postgres/postgres/data"
printf '16\n' > "$tmp/existing-postgres/postgres/data/PG_VERSION"
if "$ROOT/install.sh" --config "$tmp/wehrportal.env" --path "$tmp/existing-postgres" --dry-run >/dev/null 2>&1; then
  echo "Installer accepted an existing PostgreSQL cluster for a fresh WehrPortal install." >&2
  exit 1
fi
grep -q '^16$' "$tmp/existing-postgres/postgres/data/PG_VERSION"

mkdir -p "$tmp/existing-wehrportal/postgres/data" "$tmp/existing-wehrportal/secrets"
printf '16\n' > "$tmp/existing-wehrportal/postgres/data/PG_VERSION"
printf 'base64:preserved-test-key\n' > "$tmp/existing-wehrportal/secrets/wehrportal_app_key"
cat > "$tmp/existing-wehrportal/.env" <<'EOF'
ENABLED_APPS=wehrportal
WEHRPORTAL_IMAGE_TAG=v0.1
EOF
if ! "$ROOT/install.sh" --config "$tmp/wehrportal.env" --path "$tmp/existing-wehrportal" --dry-run >/dev/null 2>&1; then
  echo "Installer rejected a previously installed WehrPortal data directory." >&2
  exit 1
fi
grep -q '^base64:preserved-test-key$' "$tmp/existing-wehrportal/secrets/wehrportal_app_key"

sed 's/10.20.0.5/999.20.0.5/' "$tmp/remote.env" > "$tmp/invalid-ip.env"
if "$ROOT/install.sh" --config "$tmp/invalid-ip.env" --path "$tmp/invalid" --dry-run >/dev/null 2>&1; then
  echo "Installer accepted an invalid VPN address." >&2
  exit 1
fi
[[ ! -e "$tmp/invalid" ]]

cat > "$tmp/legacy-element.env" <<'EOF'
PROXY_MODE=remote
VPN_BACKEND_IP=10.20.0.5
ENABLED_APPS=matrix
BASE_DOMAIN=example.org
MATRIX_SERVER_NAME=matrix.example.org
ELEMENT_HOST=legacy-chat.example.org
ELEMENT_PORT=18090
EOF
legacy_output=$("$ROOT/install.sh" --config "$tmp/legacy-element.env" --path "$tmp/legacy-element" --dry-run)
grep -q 'FluffyChat:     legacy-chat.example.org' <<< "$legacy_output"
grep -q 'DNS Matrix Web-Messenger: legacy-chat.example.org' <<< "$legacy_output"
echo "Installer dry-run, path protection, and VPN input checks passed."
