#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
compose=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml")
[[ ! -f "$ROOT/compose.proxy.yml" ]] || compose+=(-f "$ROOT/compose.proxy.yml")
[[ ! -f "$ROOT/compose.remote.yml" ]] || compose+=(-f "$ROOT/compose.remote.yml")
"${compose[@]}" ps --all
status=$("${compose[@]}" ps --all --format '{{.State}} {{.Health}}')
if grep -Eiq '(^| )(unhealthy|restarting|exited|dead)( |$)' <<< "$status"; then
  echo "One or more containers are unhealthy or stopped." >&2
  exit 1
fi
