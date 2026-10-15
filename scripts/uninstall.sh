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
compose=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml")
[[ ! -f "$ROOT/compose.proxy.yml" ]] || compose+=(-f "$ROOT/compose.proxy.yml")
[[ ! -f "$ROOT/compose.remote.yml" ]] || compose+=(-f "$ROOT/compose.remote.yml")
echo "This removes this Compose project's containers and networks. Data remains at $ROOT."
read -r -p "Type REMOVE-CONTAINERS to continue: " answer
[[ "$answer" == REMOVE-CONTAINERS ]] || exit 1
"${compose[@]}" down
if [[ "$delete_data" == true ]]; then
  [[ $EUID -eq 0 ]] || { echo "Run data deletion as root." >&2; exit 1; }
  read -r -p "Type DELETE $ROOT to irreversibly remove secrets, backups, and all data: " answer
  [[ "$answer" == "DELETE $ROOT" ]] || exit 1
  rm -rf --one-file-system -- "$ROOT"
fi
