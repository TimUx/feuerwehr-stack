#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env; run install.sh first." >&2; exit 1; }
[[ ! -L "$ROOT/.env" ]] || { echo ".env must not be a symlink." >&2; exit 1; }

for secret in "$ROOT"/secrets/*; do
  [[ -f "$secret" ]] || continue
  mode=$(stat -c '%a' "$secret")
  (( (8#$mode & 077) == 0 )) || { echo "Insecure secret permissions: $secret" >&2; exit 1; }
done
mode=$(stat -c '%a' "$ROOT/.env")
(( (8#$mode & 077) == 0 )) || { echo "Insecure .env permissions." >&2; exit 1; }

# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
"${compose[@]}" config --quiet
if [[ "$DEPLOY_MODE" == swarm ]]; then
  python3 "$ROOT/scripts/generate-swarm-stack.py" --output /dev/null "$ROOT"
  echo "Swarm stack model and secret-file permissions are valid."
else
  echo "Compose configuration and secret-file permissions are valid."
fi
