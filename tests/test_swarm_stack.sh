#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
command -v docker >/dev/null || { echo "Docker CLI not available; Swarm stack test skipped."; exit 0; }
docker compose version >/dev/null 2>&1 || { echo "Compose plugin not available; Swarm stack test skipped."; exit 0; }
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp"/{scripts,secrets,postgres/data,keycloak/providers,keycloak/themes,wehrportal/storage/app,matrix/data,fluffychat,onlyoffice/logs,onlyoffice/data,onlyoffice/lib,grav/config}
cp "$ROOT/compose.yml" "$tmp/"
cp "$ROOT"/scripts/* "$tmp/scripts/"
for name in postgres_superuser_password keycloak_db_password wehrportal_db_password synapse_db_password \
  keycloak_admin_password wehrportal_app_key onlyoffice_jwt_secret mail_smtp_password; do
  printf 'test-only\n' > "$tmp/secrets/$name"
done
cat > "$tmp/.env" <<EOT
STACK_ROOT=$tmp
COMPOSE_PROFILES=data,keycloak,wehrportal,matrix,onlyoffice
KEYCLOAK_HOST=id.example.org
WEHRPORTAL_HOST=wehr.example.org
WEHRPORTAL_IMAGE_TAG=test-only
MATRIX_HOST=matrix.example.org
FLUFFYCHAT_HOST=chat.example.org
ONLYOFFICE_HOST=docs.example.org
MATRIX_SERVER_NAME=matrix.example.org
ACME_EMAIL=admin@example.org
TRAEFIK_MIDDLEWARES=frontend-security-chain@file
DEPLOY_MODE=swarm
EOT
chmod 0600 "$tmp/.env"
"$ROOT/scripts/generate-proxy-config.sh" "$tmp" keycloak,wehrportal,matrix,onlyoffice same-host true le shared-proxy http ""

SWARM_NODE_ID=node-test python3 "$ROOT/scripts/generate-swarm-stack.py" "$tmp"
python3 - "$tmp/stack.swarm.yml" <<'PY'
import json
import sys

stack = json.load(open(sys.argv[1], encoding="utf-8"))
services = stack["services"]
assert {"postgres", "redis", "keycloak", "wehrportal", "wehrportal-worker", "synapse", "fluffychat",
        "onlyoffice"} <= set(services), sorted(services)
for name, service in services.items():
    for option in ("depends_on", "profiles", "security_opt", "mem_limit", "cpus", "restart", "labels"):
        assert option not in service, (name, option)
    deploy = service["deploy"]
    assert deploy["placement"]["constraints"] == ["node.id == node-test"], name
    assert deploy["restart_policy"]["condition"] == "any", name
    assert deploy["resources"]["limits"]["memory"], name
    assert deploy["resources"]["limits"]["cpus"], name
    for volume in service.get("volumes", []):
        assert "create_host_path" not in volume.get("bind", {}), (name, volume)
labels = services["keycloak"]["deploy"]["labels"]
assert labels["traefik.enable"] == "true"
assert "traefik.docker.network" not in labels
assert labels["traefik.swarm.network"] == "shared-proxy"
assert labels["traefik.http.routers.fwstack-keycloak.middlewares"].startswith("frontend-security-chain@file,")
assert "traefik.enable" not in services["postgres"]["deploy"].get("labels", {})
assert stack["networks"]["proxy"] == {"external": True, "name": "shared-proxy"}
assert stack["networks"]["backend"] == {"driver": "overlay", "internal": True}
assert stack["networks"]["frontend"] == {"driver": "overlay"}
for service in services.values():
    for entry in service.get("secrets", []):
        assert entry["source"] in stack["secrets"] and entry["source"].startswith(entry["target"] + "_")
assert all(secret["file"].startswith(sys.argv[1].rsplit("/", 1)[0]) for secret in stack["secrets"].values())
PY
if docker stack config --help >/dev/null 2>&1; then
  docker stack config -c "$tmp/stack.swarm.yml" >/dev/null
fi
echo "Swarm stack generation checks passed."
