#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
for file in "$ROOT/install.sh" "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do
  bash -n "$file"
done
python3 -m py_compile "$ROOT/scripts/configure-synapse.py"
rm -rf "$ROOT/scripts/__pycache__"
if command -v shellcheck >/dev/null; then
  shellcheck "$ROOT/install.sh" "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh
fi
"$ROOT/tests/test_installer.sh"
"$ROOT/tests/test_proxy_config.sh"
"$ROOT/tests/test_compose_config.sh"
echo "All available repository tests passed."
