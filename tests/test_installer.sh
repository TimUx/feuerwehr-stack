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
grep -q 'Vorschau abgeschlossen' <<< "$output"
grep -q 'DNS Keycloak (login): login.example.org' <<< "$output"
grep -q 'DNS Matrix Server: matrix.example.org' <<< "$output"
grep -q 'Matrix OIDC: true' <<< "$output"
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
new_wehrportal_output=$("$ROOT/install.sh" --config "$tmp/wehrportal.env" --path "$tmp/new-wehrportal" --dry-run)
grep -q 'Image: ghcr.io/timux/wehrportal:latest' <<< "$new_wehrportal_output"
grep -q 'WehrPortal OIDC: false' <<< "$new_wehrportal_output"
sed 's/ENABLED_APPS=wehrportal/ENABLED_APPS=wehrportal,onlyoffice/' "$tmp/wehrportal.env" > "$tmp/portal-office.env"
office_output=$("$ROOT/install.sh" --config "$tmp/portal-office.env" --path "$tmp/portal-office" --dry-run)
grep -q 'WehrPortal Dateien: automatische ONLYOFFICE-Konfiguration' <<< "$office_output"
if grep -q 'automatische ONLYOFFICE-Konfiguration' <<< "$new_wehrportal_output"; then
  echo "Installer configured Office without selecting ONLYOFFICE." >&2; exit 1
fi
for selection in keycloak,wehrportal keycloak,wehrportal,drupal; do
  sed "s/ENABLED_APPS=wehrportal/ENABLED_APPS=$selection/" "$tmp/wehrportal.env" > "$tmp/portal-sso.env"
  portal_output=$("$ROOT/install.sh" --config "$tmp/portal-sso.env" --path "$tmp/portal-sso" --dry-run)
  grep -q 'WehrPortal OIDC: true (Notfallschalter: false)' <<< "$portal_output"
done
printf 'WEHRPORTAL_OIDC_FORCE_DISABLED=true\n' >> "$tmp/portal-sso.env"
portal_output=$("$ROOT/install.sh" --config "$tmp/portal-sso.env" --path "$tmp/portal-sso" --dry-run)
grep -q 'Notfallschalter: true' <<< "$portal_output"
[[ ! -e "$tmp/new-wehrportal" ]]
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
grep -q 'Matrix OIDC: false' <<< "$legacy_output"
grep -q 'FluffyChat:     legacy-chat.example.org' <<< "$legacy_output"
grep -q 'DNS Matrix Web-Messenger: legacy-chat.example.org' <<< "$legacy_output"
cat > "$tmp/drupal.env" <<'EOF'
PROXY_MODE=remote
VPN_BACKEND_IP=10.20.0.5
ENABLED_APPS=keycloak,drupal
BASE_DOMAIN=example.org
KEYCLOAK_REALM=feuerwehr-test
DRUPAL_ADMIN_EMAIL=admin@example.org
EOF
drupal_output=$("$ROOT/install.sh" --config "$tmp/drupal.env" --path "$tmp/drupal" --dry-run)
grep -q 'DNS Drupal Website (www): www.example.org' <<< "$drupal_output"
grep -q 'Keycloak-Realm: feuerwehr-test' <<< "$drupal_output"
grep -q 'Drupal OIDC: true' <<< "$drupal_output"
[[ ! -e "$tmp/drupal" ]]
sed 's/keycloak,drupal/drupal/' "$tmp/drupal.env" > "$tmp/drupal-local.env"
local_output=$("$ROOT/install.sh" --config "$tmp/drupal-local.env" --path "$tmp/drupal-local" --dry-run)
grep -q 'Drupal OIDC: false' <<< "$local_output"
sed 's/feuerwehr-test/master/' "$tmp/drupal.env" > "$tmp/drupal-invalid.env"
if "$ROOT/install.sh" --config "$tmp/drupal-invalid.env" --path "$tmp/invalid-realm" --dry-run >/dev/null 2>&1; then
  echo "Installer accepted master as the application realm." >&2
  exit 1
fi
echo "Installer dry-run, path protection, and VPN input checks passed."
