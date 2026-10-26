#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=scripts/lib.sh
source "$ROOT/scripts/lib.sh"
if [[ "$DEPLOY_MODE" == swarm ]]; then
  docker stack services "$STACK_NAME"
  not_ready=$(docker stack services "$STACK_NAME" --format '{{.Name}} {{.Replicas}}' |
    awk '{split($2, r, "/"); if (r[1] != r[2]) print $1}')
  not_running=$(docker stack ps "$STACK_NAME" --filter desired-state=running \
    --format '{{.Name}} {{.CurrentState}}' | awk '$2 != "Running" {print $1 " (" $2 ")"}')
  if [[ -n "$not_ready$not_running" ]]; then
    printf 'Services not fully running:\n%s\n%s\n' "$not_ready" "$not_running" >&2
    exit 1
  fi
  exit 0
fi
"${compose[@]}" ps --all
status=$("${compose[@]}" ps --all --format '{{.State}} {{.Health}}')
if grep -Eiq '(^| )(unhealthy|restarting|exited|dead)( |$)' <<< "$status"; then
  echo "One or more containers are unhealthy or stopped." >&2
  exit 1
fi
