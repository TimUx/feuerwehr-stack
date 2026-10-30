#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
if [[ "$(env_value DRUPAL_OIDC_ENABLED)" == true || "$(env_value WEHRPORTAL_OIDC_ENABLED)" == true ||
      "$(env_value MATRIX_OIDC_ENABLED)" == true ]]; then
  python3 "$ROOT/scripts/configure-keycloak.py" "$ROOT"
fi
"$ROOT/scripts/setup-drupal.sh"
"$ROOT/scripts/setup-wehrportal.sh"
"$ROOT/scripts/setup-wehrportal-office.sh"
"$ROOT/scripts/setup-synapse.sh"
