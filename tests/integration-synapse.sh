#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export RUN_MATRIX_INTEGRATION=true
exec "$ROOT/tests/integration-drupal.sh"
