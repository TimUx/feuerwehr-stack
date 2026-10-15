#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v docker >/dev/null || { echo "Docker CLI not available; Compose config validation skipped."; exit 0; }
docker compose version >/dev/null 2>&1 || { echo "Compose plugin not available; validation skipped."; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp"/{scripts,secrets,postgres/data,keycloak/providers,keycloak/themes,openwehr/source,openwehr/storage,openwehr/uploads,matrix/data,element,onlyoffice/logs,onlyoffice/data,onlyoffice/lib,grav/config,traefik/acme,integrations/traefik}
cp "$ROOT/compose.yml" "$tmp/"
cp "$ROOT"/scripts/* "$tmp/scripts/"
for name in postgres_superuser_password keycloak_db_password openwehr_db_password synapse_db_password \
  keycloak_admin_password openwehr_app_key onlyoffice_jwt_secret mail_smtp_password; do
  printf 'test-only\n' > "$tmp/secrets/$name"
done
cat > "$tmp/.env" <<EOF
STACK_ROOT=$tmp
COMPOSE_PROFILES=data,keycloak,matrix,onlyoffice,grav,proxy
KEYCLOAK_HOST=id.example.org
OPENWEHR_HOST=wehr.example.org
MATRIX_HOST=matrix.example.org
ELEMENT_HOST=chat.example.org
ONLYOFFICE_HOST=docs.example.org
GRAV_HOST=www.example.org
MATRIX_SERVER_NAME=matrix.example.org
MATRIX_FEDERATION=false
KEYCLOAK_ADMIN_USER=kcadmin
ACME_EMAIL=admin@example.org
VPN_BACKEND_IP=10.20.0.5
KEYCLOAK_PORT=18084
OPENWEHR_PORT=18080
MATRIX_PORT=18008
ELEMENT_PORT=18081
ONLYOFFICE_PORT=18082
GRAV_PORT=18083
EOF
chmod 0600 "$tmp/.env"

for mode in own same-host remote; do
  if [[ "$mode" == remote ]]; then
    "$ROOT/scripts/generate-proxy-config.sh" "$tmp" keycloak,matrix remote true "" "" http ""
  elif [[ "$mode" == own ]]; then
    "$ROOT/scripts/generate-proxy-config.sh" "$tmp" keycloak,matrix own true feuerwehr "" http ""
  else
    "$ROOT/scripts/generate-proxy-config.sh" "$tmp" matrix same-host true le shared-proxy http ""
  fi
  args=(docker compose --project-directory "$tmp" -f "$tmp/compose.yml")
  [[ ! -f "$tmp/compose.proxy.yml" ]] || args+=(-f "$tmp/compose.proxy.yml")
  [[ ! -f "$tmp/compose.remote.yml" ]] || args+=(-f "$tmp/compose.remote.yml")
  "${args[@]}" config --quiet
  rm -f "$tmp/compose.proxy.yml" "$tmp/compose.remote.yml"
done
echo "Compose model validation passed for all proxy modes."
