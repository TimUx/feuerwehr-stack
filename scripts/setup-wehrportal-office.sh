#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
apps=",$(env_value ENABLED_APPS),"
[[ "$apps" == *,wehrportal,* && "$apps" == *,onlyoffice,* ]] || exit 0
for ((attempt = 0; attempt < 120; attempt++)); do
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    container=$(swarm_container wehrportal)
    if [[ -z "$container" ]]; then sleep 5; continue; fi
    exec_command=(docker exec "$container")
  else
    exec_command=("${compose[@]}" exec -T wehrportal)
  fi
  result=0
  "${exec_command[@]}" php /stack/configure-wehrportal-office.php --check || result=$?
  if ((result == 0)); then
    "${exec_command[@]}" php /stack/configure-wehrportal-office.php
    exit 0
  fi
  ((result == 75)) || { echo "WehrPortal ONLYOFFICE compatibility check failed." >&2; exit 1; }
  sleep 5
done
echo "WehrPortal migrations or ONLYOFFICE did not become ready; check logs and rerun scripts/setup-apps.sh." >&2
exit 1
