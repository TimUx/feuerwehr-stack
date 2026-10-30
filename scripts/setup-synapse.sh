#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
[[ "$(env_value MATRIX_OIDC_ENABLED)" == true ]] || exit 0
for ((attempt = 0; attempt < 120; attempt++)); do
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    container=$(swarm_container synapse)
    if [[ -z "$container" ]]; then sleep 2; continue; fi
    exec_command=(docker exec "$container")
  else
    exec_command=("${compose[@]}" exec -T synapse)
  fi
  if "${exec_command[@]}" python -c '
import json, urllib.request
data = json.load(urllib.request.urlopen("http://127.0.0.1:8008/_matrix/client/v3/login", timeout=5))
assert any(f["type"] == "m.login.sso" and any(p["id"] == "oidc-keycloak"
    for p in f.get("identity_providers", [])) for f in data["flows"]), "Keycloak SSO flow missing"
'; then
    echo "Synapse is ready and advertises Keycloak SSO to Matrix clients."
    exit 0
  fi
  sleep 2
done
echo "Synapse SSO did not become ready. Check Synapse logs, DNS/TLS and restart Synapse after correction; rerun scripts/setup-apps.sh." >&2
exit 1
