#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export RUN_WEHRPORTAL_INTEGRATION=true RUN_OFFICE_INTEGRATION=true
exec "$ROOT/tests/integration-drupal.sh"
