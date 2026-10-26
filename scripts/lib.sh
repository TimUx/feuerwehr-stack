# shellcheck shell=bash
# Shared helpers for operations scripts. The caller must set ROOT first.

STACK_NAME=feuerwehr

env_value() {
  sed -n "s/^$1=//p" "$ROOT/.env" | head -n 1
}

DEPLOY_MODE=$(env_value DEPLOY_MODE)
DEPLOY_MODE=${DEPLOY_MODE:-compose}

compose=(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml")
[[ ! -f "$ROOT/compose.proxy.yml" ]] || compose+=(-f "$ROOT/compose.proxy.yml")
[[ ! -f "$ROOT/compose.remote.yml" ]] || compose+=(-f "$ROOT/compose.remote.yml")

swarm_container() {
  docker ps -q --filter "label=com.docker.swarm.service.name=${STACK_NAME}_$1" | head -n 1
}

# Runs a command inside the PostgreSQL container; stdin is passed through.
pg_exec() {
  if [[ "$DEPLOY_MODE" == swarm ]]; then
    local container
    container=$(swarm_container postgres)
    [[ -n "$container" ]] || { echo "PostgreSQL container is not running." >&2; return 1; }
    docker exec -i "$container" "$@"
  else
    "${compose[@]}" exec -T postgres "$@"
  fi
}

deploy_stack() {
  python3 "$ROOT/scripts/generate-swarm-stack.py" --create-bind-dirs "$ROOT"
  docker stack deploy --with-registry-auth "$@" -c "$ROOT/stack.swarm.yml" "$STACK_NAME"
}

swarm_services() {
  docker stack services "$STACK_NAME" --format '{{.Name}}'
}
