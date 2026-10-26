#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
delete_data=false
case "${1:-}" in
  "") ;;
  --delete-data) delete_data=true ;;
  -h|--help) echo "Usage: $0 [--delete-data]"; exit 0 ;;
  *) echo "Usage: $0 [--delete-data]" >&2; exit 2 ;;
esac
[[ "$ROOT" != / && -f "$ROOT/.env" && -f "$ROOT/compose.yml" ]] ||
  { echo "Not a valid installation directory." >&2; exit 1; }
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
echo "This removes this stack's containers and networks. Data remains at $ROOT."
read -r -p "Type REMOVE-CONTAINERS to continue: " answer
[[ "$answer" == REMOVE-CONTAINERS ]] || exit 1
if [[ "$DEPLOY_MODE" == swarm ]]; then
  docker stack rm "$STACK_NAME"
else
  "${compose[@]}" down
fi
if [[ "$delete_data" == true ]]; then
  [[ $EUID -eq 0 ]] || { echo "Run data deletion as root." >&2; exit 1; }
  read -r -p "Type DELETE $ROOT to irreversibly remove secrets, backups, and all data: " answer
  [[ "$answer" == "DELETE $ROOT" ]] || exit 1
  rm -rf --one-file-system -- "$ROOT"
fi
