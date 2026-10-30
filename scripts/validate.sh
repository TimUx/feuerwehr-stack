#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
[[ -f "$ROOT/.env" ]] || { echo "Missing $ROOT/.env; run install.sh first." >&2; exit 1; }
[[ ! -L "$ROOT/.env" ]] || { echo ".env must not be a symlink." >&2; exit 1; }
[[ -d "$ROOT/secrets" && ! -L "$ROOT/secrets" ]] ||
  { echo "Secrets directory is missing or unsafe." >&2; exit 1; }
mode=$(stat -c '%a' "$ROOT/secrets")
(( (8#$mode & 077) == 0 )) || { echo "Secrets directory must not be accessible to group/others." >&2; exit 1; }

for secret in "$ROOT"/secrets/*; do
  [[ ! -L "$secret" ]] || { echo "Secret must not be a symlink: $secret" >&2; exit 1; }
  [[ -f "$secret" ]] || continue
  mode=$(stat -c '%a' "$secret")
  # Readable bind-mounted files are protected on the host by the private parent directory.
  (( (8#$mode & 022) == 0 )) || { echo "Writable secret permissions: $secret" >&2; exit 1; }
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
