#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v docker >/dev/null || { echo "Docker CLI not available; Compose config validation skipped."; exit 0; }
docker compose version >/dev/null 2>&1 || { echo "Compose plugin not available; validation skipped."; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp"/{scripts,secrets,postgres/data,keycloak/providers,keycloak/themes,wehrportal/storage/app,matrix/data,fluffychat,onlyoffice/logs,onlyoffice/data,onlyoffice/lib,drupal/files,drupal/private,traefik/acme,integrations/traefik}
cp "$ROOT/compose.yml" "$tmp/"
cp "$ROOT"/scripts/* "$tmp/scripts/"
for name in postgres_superuser_password keycloak_db_password wehrportal_db_password synapse_db_password \
  keycloak_admin_password wehrportal_app_key onlyoffice_jwt_secret mail_smtp_password \
  drupal_db_password drupal_hash_salt drupal_admin_password drupal_oidc_client_secret wehrportal_oidc_client_secret synapse_oidc_client_secret; do
  printf 'test-only\n' > "$tmp/secrets/$name"
  chmod 0644 "$tmp/secrets/$name"
done
cat > "$tmp/.env" <<EOF
STACK_ROOT=$tmp
COMPOSE_PROFILES=data,keycloak,wehrportal,matrix,onlyoffice,drupal,proxy
KEYCLOAK_HOST=id.example.org
WEHRPORTAL_HOST=wehr.example.org
WEHRPORTAL_IMAGE_TAG=test-only
WEHRPORTAL_OIDC_ENABLED=true
WEHRPORTAL_OIDC_FORCE_DISABLED=true
MATRIX_HOST=matrix.example.org
FLUFFYCHAT_HOST=chat.example.org
ONLYOFFICE_HOST=docs.example.org
DRUPAL_HOST=www.example.org
MATRIX_SERVER_NAME=matrix.example.org
MATRIX_FEDERATION=false
MATRIX_OIDC_ENABLED=true
KEYCLOAK_ADMIN_USER=kcadmin
ACME_EMAIL=admin@example.org
VPN_BACKEND_IP=10.20.0.5
KEYCLOAK_PORT=18084
WEHRPORTAL_PORT=18080
MATRIX_PORT=18008
FLUFFYCHAT_PORT=18081
ONLYOFFICE_PORT=18082
DRUPAL_PORT=18083
EOF
cat > "$tmp/fluffychat/config.json" <<'EOF'
{"applicationName":"FluffyChat","defaultHomeserver":"matrix.example.org"}
EOF
chmod 0600 "$tmp/.env"
chmod 0700 "$tmp/secrets"
bash "$tmp/scripts/validate.sh" >/dev/null
chmod 0666 "$tmp/secrets/drupal_oidc_client_secret"
if bash "$tmp/scripts/validate.sh" >/dev/null 2>&1; then
  echo "Validator accepted a writable Drupal secret." >&2
  exit 1
fi
chmod 0644 "$tmp/secrets/drupal_oidc_client_secret"

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
  "${args[@]}" config --format json > "$tmp/config.json"
  python3 - "$tmp/config.json" "$mode" <<'PY'
import json
import sys

configuration = json.load(open(sys.argv[1], encoding="utf-8"))
mode = sys.argv[2]
portal = configuration["services"]["wehrportal"]
assert portal["image"] == "ghcr.io/timux/wehrportal:test-only", portal["image"]
assert portal["environment"]["AUTORUN_ENABLED"] == "true"
assert "build" not in portal
assert configuration["services"]["wehrportal-worker"]["image"] == portal["image"]
for service in (portal, configuration["services"]["wehrportal-worker"]):
    assert service["environment"]["OIDC_ENABLED"] == "true"
    assert service["environment"]["OIDC_FORCE_DISABLED"] == "true"
assert any(s["source"] == "wehrportal_oidc_client_secret" for s in portal["secrets"])
assert not any(s["source"] == "wehrportal_oidc_client_secret"
               for s in configuration["services"]["wehrportal-worker"]["secrets"])
assert not any(s["source"] == "keycloak_admin_password" for s in portal["secrets"])
assert portal["environment"]["ONLYOFFICE_HOST"] == "docs.example.org"
assert any(s["source"] == "onlyoffice_jwt_secret" for s in portal["secrets"])
assert any(v["target"] == "/stack/configure-wehrportal-office.php" for v in portal["volumes"])
assert not any(s["source"] == "onlyoffice_jwt_secret"
               for s in configuration["services"]["wehrportal-worker"]["secrets"])
assert configuration["services"]["postgres"]["image"] == "postgres:latest"
assert configuration["services"]["redis"]["image"] == "redis:latest"
assert configuration["services"]["keycloak"]["image"] == "quay.io/keycloak/keycloak:latest"
assert configuration["services"]["synapse"]["image"] == "matrixdotorg/synapse:latest"
assert configuration["services"]["synapse"]["environment"]["MATRIX_OIDC_ENABLED"] == "true"
assert configuration["services"]["synapse"]["entrypoint"] == ["/bin/sh", "/stack/synapse-entrypoint.sh"]
assert any(s["source"] == "synapse_oidc_client_secret" for s in configuration["services"]["synapse"]["secrets"])
assert configuration["services"]["fluffychat"]["image"] == "ghcr.io/etkecc/fluffychat-web:latest"
assert configuration["services"]["onlyoffice"]["image"] == "onlyoffice/documentserver:latest"
drupal = configuration["services"]["drupal"]
assert drupal["image"] == "feuerwehr/drupal:11.4.11-1"
assert drupal["build"]["context"].endswith("/drupal")
assert "backend" in drupal["networks"]
assert configuration["services"]["postgres"]["environment"]["DRUPAL_DB_PASSWORD_FILE"] == \
    "/run/secrets/drupal_db_password"
assert configuration["services"]["traefik"]["image"] == "traefik:latest"
assert configuration["services"]["postgres"]["environment"]["WEHRPORTAL_DB_PASSWORD_FILE"] == \
    "/run/secrets/wehrportal_db_password"
assert configuration["services"]["postgres"]["environment"]["PGDATA"] == "/var/lib/postgresql/data"
published = {
    service: service_config.get("ports", [])
    for service, service_config in configuration["services"].items()
    if service_config.get("ports")
}
if mode != "own":
    published.pop("traefik", None)  # The proxy profile is not enabled in those modes.
if mode == "own":
    assert set(published) == {"traefik"}, published
    assert {entry["target"] for entry in published["traefik"]} == {80, 443}
elif mode == "same-host":
    assert not published, published
else:
    assert set(published) == {"keycloak", "synapse", "fluffychat"}, published
    assert all(entry["host_ip"] == "10.20.0.5" for ports in published.values() for entry in ports)
PY
  rm -f "$tmp/compose.proxy.yml" "$tmp/compose.remote.yml"
done
echo "Compose model validation passed for all proxy modes."
