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

sed 's/10.20.0.5/999.20.0.5/' "$tmp/remote.env" > "$tmp/invalid-ip.env"
if "$ROOT/install.sh" --config "$tmp/invalid-ip.env" --path "$tmp/invalid" --dry-run >/dev/null 2>&1; then
  echo "Installer accepted an invalid VPN address." >&2
  exit 1
fi
[[ ! -e "$tmp/invalid" ]]
echo "Installer dry-run, path protection, and VPN input checks passed."
