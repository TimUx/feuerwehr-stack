#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/integrations/traefik"
cat > "$tmp/.env" <<'EOF'
KEYCLOAK_HOST=id.example.org
WEHRPORTAL_HOST=portal.example.org
MATRIX_HOST=matrix.example.org
FLUFFYCHAT_HOST=chat.example.org
ONLYOFFICE_HOST=docs.example.org
GRAV_HOST=www.example.org
VPN_BACKEND_IP=10.20.0.5
KEYCLOAK_PORT=18084
WEHRPORTAL_PORT=18080
MATRIX_PORT=18008
FLUFFYCHAT_PORT=18081
ONLYOFFICE_PORT=18082
GRAV_PORT=18083
EOF

"$ROOT/scripts/generate-proxy-config.sh" "$tmp" keycloak,wehrportal,matrix own true feuerwehr "" http ""
grep -q 'fwstack-keycloak.rule' "$tmp/compose.proxy.yml"
grep -q 'id.example.org' "$tmp/compose.proxy.yml"
grep -q 'fwstack-synapse.rule' "$tmp/compose.proxy.yml"
grep -q 'matrix.example.org' "$tmp/compose.proxy.yml"
grep -q 'fwstack-fluffychat.rule' "$tmp/compose.proxy.yml"
if grep -q 'openwehr' "$tmp/compose.proxy.yml"; then exit 1; fi
grep -q 'fwstack-wehrportal.rule' "$tmp/compose.proxy.yml"
grep -q 'portal.example.org' "$tmp/compose.proxy.yml"

"$ROOT/scripts/generate-proxy-config.sh" "$tmp" matrix same-host true le shared-proxy http ""
grep -q 'name: shared-proxy' "$tmp/compose.proxy.yml"
grep -q 'traefik.docker.network: "shared-proxy"' "$tmp/compose.proxy.yml"
grep -q 'fwstack-fluffychat' "$tmp/compose.proxy.yml"

"$ROOT/scripts/generate-proxy-config.sh" "$tmp" matrix same-host false le shared-proxy http ""
[[ ! -e "$tmp/compose.proxy.yml" ]]

"$ROOT/scripts/generate-proxy-config.sh" "$tmp" keycloak,wehrportal,matrix remote true "" "" http ""
grep -q 'url: "http://10.20.0.5:18080"' "$tmp/integrations/traefik/dynamic.yml"
grep -q 'url: "http://10.20.0.5:18008"' "$tmp/integrations/traefik/dynamic.yml"
grep -q 'matrix.example.org' "$tmp/integrations/traefik/dynamic.yml"
grep -Fq "\${VPN_BACKEND_IP}:18008:8008" "$tmp/compose.remote.yml"
if grep -Eq 'postgres|redis|openwehr' "$tmp/integrations/traefik/dynamic.yml"; then exit 1; fi
"$ROOT/scripts/generate-proxy-config.sh" "$tmp" matrix remote true "" "" http ""
grep -q 'fluffychat' "$tmp/integrations/traefik/dynamic.yml"
grep -q '18081:8080' "$tmp/compose.remote.yml"
"$ROOT/scripts/generate-proxy-config.sh" "$tmp" matrix remote false "" "" http ""
[[ ! -e "$tmp/compose.remote.yml" && ! -e "$tmp/integrations/traefik/dynamic.yml" ]]
echo "Own, existing, and remote proxy configuration checks passed."
