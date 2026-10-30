#!/usr/bin/env bash
set -Eeuo pipefail

root=$1
apps_csv=$2
mode=$3
routes=$4
resolver=$5
network=$6
challenge=$7
provider=$8

env_value() {
  sed -n "s/^$1=//p" "$root/.env" | head -n 1
}

IFS=',' read -r -a apps <<< "$apps_csv"
vpn_ip=$(env_value VPN_BACKEND_IP)
# Plain "docker compose" only loads override files that are listed in COMPOSE_FILE
sync_compose_file() {
  local files=compose.yml tmp
  [[ ! -f "$root/compose.proxy.yml" ]] || files+=:compose.proxy.yml
  [[ ! -f "$root/compose.remote.yml" ]] || files+=:compose.remote.yml
  tmp=$(mktemp "$root/.env.XXXXXX")
  { grep -v '^COMPOSE_FILE=' "$root/.env" || true; printf 'COMPOSE_FILE=%s\n' "$files"; } > "$tmp"
  chmod 0600 "$tmp"
  mv "$tmp" "$root/.env"
}

rm -f "$root/compose.proxy.yml" "$root/compose.remote.yml" \
  "$root/integrations/traefik/dynamic.yml"

if [[ "$mode" == remote ]]; then
  [[ "$routes" == true ]] || { sync_compose_file; exit 0; }
  mkdir -p "$root/integrations/traefik"
  routers=$(mktemp)
  backends=$(mktemp)
  bindings=$(mktemp)
  trap 'rm -f "$routers" "$backends" "$bindings"' EXIT

  add_remote() {
    local name=$1 host=$2 host_port=$3 container_port=$4
    local route="fwstack-${name}"
    cat >> "$routers" <<EOF
    ${route}:
      rule: "Host(\`${host}\`)"
      entryPoints: [websecure]
      service: ${route}
      middlewares: [feuerwehr-forwarded]
      tls: {}
EOF
    cat >> "$backends" <<EOF
    ${route}:
      loadBalancer:
        servers:
          - url: "http://${vpn_ip}:${host_port}"
        serversTransport: feuerwehr-timeouts
EOF
    cat >> "$bindings" <<EOF
  ${name}:
    ports:
      - "\${VPN_BACKEND_IP}:${host_port}:${container_port}"
EOF
  }
  for app in "${apps[@]}"; do
    case "$app" in
      keycloak) add_remote keycloak "$(env_value KEYCLOAK_HOST)" "$(env_value KEYCLOAK_PORT)" 8080 ;;
      wehrportal) add_remote wehrportal "$(env_value WEHRPORTAL_HOST)" "$(env_value WEHRPORTAL_PORT)" 8080 ;;
      matrix)
        add_remote synapse "$(env_value MATRIX_HOST)" "$(env_value MATRIX_PORT)" 8008
        add_remote fluffychat "$(env_value FLUFFYCHAT_HOST)" "$(env_value FLUFFYCHAT_PORT)" 8080
        ;;
      onlyoffice) add_remote onlyoffice "$(env_value ONLYOFFICE_HOST)" "$(env_value ONLYOFFICE_PORT)" 80 ;;
      drupal) add_remote drupal "$(env_value DRUPAL_HOST)" "$(env_value DRUPAL_PORT)" 80 ;;
    esac
  done
  {
    printf 'http:\n  routers:\n'
    cat "$routers"
    printf '  services:\n'
    cat "$backends"
    cat <<'EOF'
  middlewares:
    feuerwehr-forwarded:
      headers:
        customRequestHeaders:
          X-Forwarded-Proto: https
  serversTransports:
    feuerwehr-timeouts:
      forwardingTimeouts:
        dialTimeout: 30s
        responseHeaderTimeout: 300s
        idleConnTimeout: 300s
EOF
  } > "$root/integrations/traefik/dynamic.yml"
  {
    printf 'services:\n'
    cat "$bindings"
  } > "$root/compose.remote.yml"
  chmod 0640 "$root/integrations/traefik/dynamic.yml" "$root/compose.remote.yml"
  sync_compose_file
  exit 0
fi

[[ "$routes" == true ]] || { sync_compose_file; exit 0; }
{
  printf 'services:\n'
  extra_middlewares=$(env_value TRAEFIK_MIDDLEWARES)
  add_labels() {
    local service=$1 host=$2 port=$3 chain="fwstack-$1-headers"
    [[ -z "$extra_middlewares" ]] || chain="${extra_middlewares},${chain}"
    cat <<EOF
  ${service}:
    labels:
      traefik.enable: "true"
      traefik.docker.network: "${network:-feuerwehr_frontend}"
      traefik.swarm.network: "${network:-feuerwehr_frontend}"
      traefik.http.routers.fwstack-${service}.rule: "Host(\`${host}\`)"
      traefik.http.routers.fwstack-${service}.entrypoints: websecure
      traefik.http.routers.fwstack-${service}.tls: "true"
      traefik.http.routers.fwstack-${service}.tls.certresolver: ${resolver}
      traefik.http.routers.fwstack-${service}.middlewares: "${chain}"
      traefik.http.middlewares.fwstack-${service}-headers.headers.customrequestheaders.X-Forwarded-Proto: https
      traefik.http.routers.fwstack-${service}.service: "fwstack-${service}"
      traefik.http.services.fwstack-${service}.loadbalancer.server.port: "${port}"
EOF
    if [[ "$mode" == same-host ]]; then
      cat <<'EOF'
    networks:
      - proxy
EOF
    fi
  }
  for app in "${apps[@]}"; do
    case "$app" in
      keycloak) add_labels keycloak "$(env_value KEYCLOAK_HOST)" 8080 ;;
      wehrportal) add_labels wehrportal "$(env_value WEHRPORTAL_HOST)" 8080 ;;
      matrix)
        add_labels synapse "$(env_value MATRIX_HOST)" 8008
        add_labels fluffychat "$(env_value FLUFFYCHAT_HOST)" 8080
        ;;
      onlyoffice) add_labels onlyoffice "$(env_value ONLYOFFICE_HOST)" 80 ;;
      drupal) add_labels drupal "$(env_value DRUPAL_HOST)" 80 ;;
    esac
  done
  if [[ "$mode" == same-host ]]; then
    cat <<EOF
networks:
  proxy:
    external: true
    name: ${network}
EOF
  fi
  if [[ "$mode" == own && "$challenge" == dns ]]; then
    [[ -f "$root/secrets/dns.env" ]] || {
      echo "DNS-01 selected: create $root/secrets/dns.env with the provider's required variables." >&2
      exit 1
    }
    cat <<EOF
  traefik:
    env_file:
      - ./secrets/dns.env
    command:
      - --api.dashboard=false
      - --ping=true
      - --providers.docker=true
      - --providers.docker.exposedbydefault=false
      - --providers.docker.network=feuerwehr_frontend
      - --entrypoints.web.address=:80
      - --entrypoints.websecure.address=:443
      - --entrypoints.web.http.redirections.entrypoint.to=websecure
      - --entrypoints.web.http.redirections.entrypoint.scheme=https
      - --certificatesresolvers.feuerwehr.acme.email=\${ACME_EMAIL}
      - --certificatesresolvers.feuerwehr.acme.storage=/letsencrypt/acme.json
      - --certificatesresolvers.feuerwehr.acme.dnschallenge.provider=${provider}
EOF
  fi
} > "$root/compose.proxy.yml"
chmod 0640 "$root/compose.proxy.yml"
sync_compose_file
