#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_PATH=/srv/apps/feuerwehr
INSTALL_PATH=$DEFAULT_PATH
CONFIG_FILE=
DNS_ENV_FILE=
OPENWEHR_SOURCE=
DRY_RUN=false
NO_START=false
ASSUME_YES=false
PATH_EXPLICIT=false
declare -A values=()
declare -A supplied=()
declare -A allowed=()

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [options]

Options:
  --path PATH              Installation root (default: /srv/apps/feuerwehr)
  --config FILE            Read KEY=VALUE settings (never evaluated as shell)
  --openwehr-source DIR    Copy a checked-out OpenWehr source tree
  --dns-env-file FILE      Copy protected Traefik DNS-provider environment
  --dry-run                Validate and summarize without changing the host
  --no-start               Prepare files but do not start containers
  --yes                    Skip the confirmation prompt
  -h, --help               Show this help

Config keys: INSTALL_PATH, BASE_DOMAIN, ACME_EMAIL, PROXY_MODE, ENABLED_APPS,
ENABLE_PROXY_ROUTES, TRAEFIK_NETWORK, TRAEFIK_CERT_RESOLVER, ACME_CHALLENGE,
ACME_DNS_PROVIDER, ACME_DNS_ENV_FILE, MATRIX_SERVER_NAME, MATRIX_FEDERATION,
VPN_BACKEND_IP, KEYCLOAK_HOST, OPENWEHR_HOST, MATRIX_HOST, ELEMENT_HOST,
ONLYOFFICE_HOST, GRAV_HOST, KEYCLOAK_ADMIN_USER, OPENWEHR_SOURCE, MAIL_HOST,
MAIL_PORT, MAIL_USERNAME, MAIL_ENCRYPTION, MAIL_FROM_ADDRESS, MAIL_FROM_NAME,
KEYCLOAK_PORT, OPENWEHR_PORT, MATRIX_PORT, ELEMENT_PORT, ONLYOFFICE_PORT,
GRAV_PORT.
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

while (($#)); do
  case "$1" in
    --path) (($# >= 2)) || fail "--path requires a value"; INSTALL_PATH=$2; PATH_EXPLICIT=true; shift 2 ;;
    --config) (($# >= 2)) || fail "--config requires a file"; CONFIG_FILE=$2; shift 2 ;;
    --openwehr-source) (($# >= 2)) || fail "--openwehr-source requires a directory"; OPENWEHR_SOURCE=$2; shift 2 ;;
    --dns-env-file) (($# >= 2)) || fail "--dns-env-file requires a file"; DNS_ENV_FILE=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-start) NO_START=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
done

for key in INSTALL_PATH BASE_DOMAIN ACME_EMAIL PROXY_MODE ENABLED_APPS ENABLE_PROXY_ROUTES \
  TRAEFIK_NETWORK TRAEFIK_CERT_RESOLVER ACME_CHALLENGE ACME_DNS_PROVIDER ACME_DNS_ENV_FILE \
  MATRIX_SERVER_NAME MATRIX_FEDERATION VPN_BACKEND_IP KEYCLOAK_HOST OPENWEHR_HOST MATRIX_HOST \
  ELEMENT_HOST ONLYOFFICE_HOST GRAV_HOST KEYCLOAK_ADMIN_USER OPENWEHR_SOURCE MAIL_HOST MAIL_PORT \
  MAIL_USERNAME MAIL_ENCRYPTION MAIL_FROM_ADDRESS MAIL_FROM_NAME KEYCLOAK_PORT OPENWEHR_PORT \
  MATRIX_PORT ELEMENT_PORT ONLYOFFICE_PORT GRAV_PORT; do
  allowed["$key"]=1
done

read_config() {
  local file=$1 line key value
  [[ -f "$file" && -r "$file" ]] || fail "Configuration file is not readable: $file"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    [[ "$line" == *=* ]] || fail "Invalid configuration line in $file"
    key=${line%%=*}
    value=${line#*=}
    key=${key//[[:space:]]/}
    [[ -n "${allowed[$key]:-}" ]] || continue
    value=${value%$'\r'}
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value=${BASH_REMATCH[1]}
    fi
    [[ "$value" != *$'\n'* ]] ||
      fail "Unsafe value in configuration key $key"
    supplied["$key"]=$value
  done < "$file"
}

[[ -z "$CONFIG_FILE" ]] || read_config "$CONFIG_FILE"
if [[ "$PATH_EXPLICIT" != true ]]; then
  INSTALL_PATH=${supplied[INSTALL_PATH]:-$DEFAULT_PATH}
  if [[ -z "$CONFIG_FILE" && -t 0 && "$DRY_RUN" == false ]]; then
    read -r -p "Installationspfad [$INSTALL_PATH]: " answer
    INSTALL_PATH=${answer:-$INSTALL_PATH}
  fi
fi
[[ "$INSTALL_PATH" == /* && "$INSTALL_PATH" != / ]] || fail "Installation path must be absolute and not /"
INSTALL_PATH="$(realpath -m -- "$INSTALL_PATH")"
[[ "$INSTALL_PATH" != / && "$INSTALL_PATH" != *$'\n'* ]] || fail "Invalid installation path"

if [[ -f "$INSTALL_PATH/.env" ]]; then
  read_config "$INSTALL_PATH/.env"
fi
for key in "${!supplied[@]}"; do values["$key"]=${supplied[$key]}; done

prompt() {
  local key=$1 prompt_text=$2 default=$3 answer
  [[ -v "values[$key]" ]] && return
  if [[ -t 0 && "$DRY_RUN" == false ]]; then
    read -r -p "$prompt_text [$default]: " answer
    values["$key"]=${answer:-$default}
  else
    values["$key"]=$default
  fi
}

prompt BASE_DOMAIN "Basisdomain" feuerwehr.example.de
prompt ACME_EMAIL "Let's Encrypt E-Mail-Adresse" admin@example.de
prompt PROXY_MODE "Reverse-Proxy-Modus (own/same-host/remote)" own
prompt ENABLED_APPS "Aktive Anwendungen (keycloak,openwehr,matrix,onlyoffice,grav)" keycloak,openwehr
prompt ENABLE_PROXY_ROUTES "Proxy-Routen aktivieren (true/false)" true
prompt TRAEFIK_NETWORK "Vorhandenes Traefik-Docker-Netzwerk" ""
prompt TRAEFIK_CERT_RESOLVER "Zertifikatsresolver des vorhandenen Traefik" ""
prompt ACME_CHALLENGE "Let's Encrypt Challenge (http/dns)" http
prompt ACME_DNS_PROVIDER "Traefik DNS-Provider (nur DNS-01)" ""
prompt ACME_DNS_ENV_FILE "Provider-Variablen-Datei für DNS-01" ""
prompt MATRIX_SERVER_NAME "Matrix Server-Name (Federation)" matrix.feuerwehr.example.de
prompt MATRIX_FEDERATION "Matrix Federation aktivieren (true/false)" false
prompt VPN_BACKEND_IP "VPN-IP des Backend-Hosts (Remote-Modus)" ""
prompt KEYCLOAK_HOST "Keycloak-Subdomain" "id.${values[BASE_DOMAIN]}"
prompt OPENWEHR_HOST "OpenWehr-Subdomain" "wehr.${values[BASE_DOMAIN]}"
prompt MATRIX_HOST "Matrix-API-Subdomain" "matrix.${values[BASE_DOMAIN]}"
prompt ELEMENT_HOST "Element-Subdomain" "chat.${values[BASE_DOMAIN]}"
prompt ONLYOFFICE_HOST "ONLYOFFICE-Subdomain" "docs.${values[BASE_DOMAIN]}"
prompt GRAV_HOST "GRAV-Subdomain" "www.${values[BASE_DOMAIN]}"
prompt KEYCLOAK_ADMIN_USER "Initialer Keycloak-Administrator" kcadmin
prompt OPENWEHR_SOURCE "OpenWehr-Quellverzeichnis (nur wenn ausgewählt)" ""
prompt MAIL_HOST "SMTP-Server für OpenWehr (Magic-Link-Anmeldung)" ""
prompt MAIL_PORT "SMTP-Port" 587
prompt MAIL_USERNAME "SMTP-Benutzername" ""
prompt MAIL_ENCRYPTION "SMTP-Verschlüsselung (tls/ssl/leer)" tls
prompt MAIL_FROM_ADDRESS "Absenderadresse für OpenWehr" ""
prompt MAIL_FROM_NAME "Absendername für OpenWehr" Feuerwehr

valid_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
for key in BASE_DOMAIN KEYCLOAK_HOST OPENWEHR_HOST MATRIX_HOST ELEMENT_HOST ONLYOFFICE_HOST GRAV_HOST MATRIX_SERVER_NAME; do
  valid_domain "${values[$key]}" || fail "Invalid domain: ${values[$key]}"
done
[[ "${values[KEYCLOAK_ADMIN_USER]}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "Invalid KEYCLOAK_ADMIN_USER"
[[ "${values[MAIL_HOST]}" == "" || "${values[MAIL_HOST]}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid MAIL_HOST"
[[ "${values[MAIL_USERNAME]}" == "" || "${values[MAIL_USERNAME]}" =~ ^[A-Za-z0-9@._+-]+$ ]] ||
  fail "MAIL_USERNAME contains unsupported characters"
mail_from_name_re='^[A-Za-z0-9 _.-]{1,64}$'
[[ "${values[MAIL_FROM_NAME]}" =~ $mail_from_name_re ]] || fail "Invalid MAIL_FROM_NAME"
[[ "${values[MAIL_ENCRYPTION]}" =~ ^(tls|ssl|)$ ]] || fail "MAIL_ENCRYPTION must be tls, ssl, or empty"
[[ "${values[PROXY_MODE]}" =~ ^(own|same-host|remote)$ ]] || fail "PROXY_MODE must be own, same-host, or remote"
[[ "${values[ACME_CHALLENGE]}" =~ ^(http|dns)$ ]] || fail "ACME_CHALLENGE must be http or dns"
[[ "${values[ENABLE_PROXY_ROUTES]}" =~ ^(true|false)$ ]] || fail "ENABLE_PROXY_ROUTES must be true or false"
[[ "${values[MATRIX_FEDERATION]}" =~ ^(true|false)$ ]] || fail "MATRIX_FEDERATION must be true or false"
[[ "${values[PROXY_MODE]}" == own || "${values[ACME_CHALLENGE]}" == http ]] ||
  fail "ACME challenge selection is used only with own Traefik"
[[ "${values[PROXY_MODE]}" != same-host || -n "${values[TRAEFIK_NETWORK]}" ]] ||
  fail "TRAEFIK_NETWORK is required for same-host mode"
[[ -z "${values[TRAEFIK_NETWORK]}" || "${values[TRAEFIK_NETWORK]}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
  fail "Invalid TRAEFIK_NETWORK"
[[ "${values[PROXY_MODE]}" != same-host || "${values[ENABLE_PROXY_ROUTES]}" != true || -n "${values[TRAEFIK_CERT_RESOLVER]}" ]] ||
  fail "Set TRAEFIK_CERT_RESOLVER before enabling routes on existing Traefik"
[[ -z "${values[TRAEFIK_CERT_RESOLVER]}" || "${values[TRAEFIK_CERT_RESOLVER]}" =~ ^[A-Za-z0-9_-]+$ ]] ||
  fail "Invalid TRAEFIK_CERT_RESOLVER"
if [[ "${values[PROXY_MODE]}" == own ]]; then
  [[ "${values[ACME_EMAIL]}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "Invalid ACME_EMAIL"
fi
if [[ "${values[ACME_CHALLENGE]}" == dns ]]; then
  [[ "${values[ACME_DNS_PROVIDER]}" =~ ^[a-z0-9]+$ ]] || fail "DNS-01 requires a valid Traefik DNS provider"
  DNS_ENV_FILE=${DNS_ENV_FILE:-${values[ACME_DNS_ENV_FILE]}}
fi

IFS=',' read -r -a apps <<< "${values[ENABLED_APPS]}"
declare -A enabled=()
for app in "${apps[@]}"; do
  case "$app" in keycloak|openwehr|matrix|onlyoffice|grav) ;; *) fail "Unknown application: $app";; esac
  [[ -z "${enabled[$app]:-}" ]] || fail "Duplicate application: $app"
  enabled["$app"]=1
done
[[ ${#enabled[@]} -gt 0 ]] || fail "Select at least one application"

if [[ "${values[PROXY_MODE]}" == remote ]]; then
  [[ "${values[VPN_BACKEND_IP]}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || fail "Remote mode requires an IPv4 VPN_BACKEND_IP"
  IFS=. read -r -a octets <<< "${values[VPN_BACKEND_IP]}"
  for octet in "${octets[@]}"; do ((10#$octet <= 255)) || fail "Invalid IPv4 address"; done
  [[ ${#octets[@]} -eq 4 ]] || fail "Invalid IPv4 address"
fi

for key in KEYCLOAK_PORT OPENWEHR_PORT MATRIX_PORT ELEMENT_PORT ONLYOFFICE_PORT GRAV_PORT; do
  default=18080
  case "$key" in
    KEYCLOAK_PORT) default=18084 ;;
    OPENWEHR_PORT) default=18080 ;;
    MATRIX_PORT) default=18008 ;;
    ELEMENT_PORT) default=18081 ;;
    ONLYOFFICE_PORT) default=18082 ;;
    GRAV_PORT) default=18083 ;;
  esac
  prompt "$key" "$key (VPN-bound port)" "$default"
  if [[ ! "${values[$key]}" =~ ^[0-9]+$ ]] ||
      ((10#${values[$key]} < 1024 || 10#${values[$key]} > 65535)); then
    fail "Invalid port for $key"
  fi
done
if [[ "${values[PROXY_MODE]}" == remote ]]; then
  selected_ports=()
  for app in "${apps[@]}"; do
    case "$app" in
      keycloak) selected_ports+=("${values[KEYCLOAK_PORT]}") ;;
      openwehr) selected_ports+=("${values[OPENWEHR_PORT]}") ;;
      matrix) selected_ports+=("${values[MATRIX_PORT]}" "${values[ELEMENT_PORT]}") ;;
      onlyoffice) selected_ports+=("${values[ONLYOFFICE_PORT]}") ;;
      grav) selected_ports+=("${values[GRAV_PORT]}") ;;
    esac
  done
  [[ $(printf '%s\n' "${selected_ports[@]}" | sort -u | wc -l) -eq ${#selected_ports[@]} ]] ||
    fail "Remote backend ports must be unique"
fi

if [[ -n "${enabled[openwehr]:-}" ]]; then
  OPENWEHR_SOURCE=${OPENWEHR_SOURCE:-${values[OPENWEHR_SOURCE]:-}}
  if [[ -z "$OPENWEHR_SOURCE" && -f "$INSTALL_PATH/openwehr/source/Dockerfile" ]]; then
    OPENWEHR_SOURCE=$INSTALL_PATH/openwehr/source
  fi
  [[ -z "$OPENWEHR_SOURCE" || -f "$OPENWEHR_SOURCE/Dockerfile" ]] ||
    fail "OpenWehr source directory has no Dockerfile: $OPENWEHR_SOURCE"
  [[ -n "${values[MAIL_HOST]}" && -n "${values[MAIL_FROM_ADDRESS]}" ]] ||
    fail "OpenWehr magic-link login requires MAIL_HOST and MAIL_FROM_ADDRESS"
  [[ "${values[MAIL_FROM_ADDRESS]}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    fail "Invalid MAIL_FROM_ADDRESS"
fi
[[ -z "$DNS_ENV_FILE" || -r "$DNS_ENV_FILE" ]] || fail "DNS provider file is not readable"
if [[ "${values[PROXY_MODE]}" == own && "${values[ACME_CHALLENGE]}" == dns && -z "$DNS_ENV_FILE" &&
      ! -f "$INSTALL_PATH/secrets/dns.env" ]]; then
  fail "DNS-01 requires --dns-env-file or an existing $INSTALL_PATH/secrets/dns.env"
fi

if [[ "${values[PROXY_MODE]}" == own ]]; then
  command -v ss >/dev/null || fail "ss is required to check ports 80 and 443"
  for port in 80 443; do
    ss -H -ltn "sport = :$port" | grep -q . && fail "TCP port $port is already in use"
  done
fi
if [[ "${values[PROXY_MODE]}" == same-host && "$DRY_RUN" == false ]]; then
  command -v docker >/dev/null || fail "Docker is required to inspect the proxy network"
  docker network inspect "${values[TRAEFIK_NETWORK]}" >/dev/null 2>&1 ||
    fail "Docker network does not exist: ${values[TRAEFIK_NETWORK]}"
fi
if [[ -d "$INSTALL_PATH" && -n "$(find "$INSTALL_PATH" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" &&
      ! -f "$INSTALL_PATH/.env" ]]; then
  fail "Refusing to use non-empty directory without an existing stack .env: $INSTALL_PATH"
fi

if [[ "$DRY_RUN" == false ]]; then
  [[ $EUID -eq 0 ]] || fail "Run as root (for example: sudo ./install.sh)"
  [[ -r /etc/os-release ]] || fail "Cannot identify the operating system"
  # shellcheck disable=SC1091
  source /etc/os-release
  case "${ID:-}" in debian|ubuntu|raspbian) ;; *) fail "Supported operating systems: Debian and Ubuntu";; esac
  command -v docker >/dev/null || fail "Docker Engine is not installed"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin is required"
  command -v openssl >/dev/null || fail "openssl is required to generate secrets"
  mkdir -p "$(dirname -- "$INSTALL_PATH")"
  available_kb=$(df -Pk "$(dirname -- "$INSTALL_PATH")" | awk 'NR==2 {print $4}')
  (( available_kb >= 2097152 )) || fail "At least 2 GiB free disk space is required"
fi

profiles=data
for app in "${apps[@]}"; do profiles+=",${app}"; done
[[ "${values[PROXY_MODE]}" != own ]] || profiles+=",proxy"
values[STACK_ROOT]=$INSTALL_PATH
values[COMPOSE_PROFILES]=$profiles
values[ENABLED_APPS]=$(IFS=,; echo "${apps[*]}")

cat <<EOF
Installation summary
  Path:           $INSTALL_PATH
  Applications:   ${values[ENABLED_APPS]}
  Proxy mode:     ${values[PROXY_MODE]}
  Proxy routes:   ${values[ENABLE_PROXY_ROUTES]}
  Base domain:    ${values[BASE_DOMAIN]}
  TLS challenge:  ${values[ACME_CHALLENGE]}
  Matrix server:  ${values[MATRIX_SERVER_NAME]} (federation: ${values[MATRIX_FEDERATION]})
  Start services: $([[ "$NO_START" == true ]] && echo no || echo yes)
EOF

if [[ "$DRY_RUN" == true ]]; then
  info "Dry run complete; no files or services were changed."
  exit 0
fi
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Continue? [y/N] " answer
  [[ "$answer" == y || "$answer" == Y || "$answer" == yes || "$answer" == YES ]] || exit 1
fi

install -d -m 0750 "$INSTALL_PATH"
install -d -m 0750 "$INSTALL_PATH"/{secrets,postgres/data,keycloak/providers,keycloak/themes,openwehr/source,openwehr/storage,openwehr/uploads,matrix/data,element,onlyoffice/logs,onlyoffice/data,onlyoffice/lib,grav/config,traefik/acme,backups,logs,integrations/traefik}
install -d -m 0750 "$INSTALL_PATH/scripts"
for file in compose.yml scripts/postgres-init.sh scripts/keycloak-entrypoint.sh scripts/openwehr-entrypoint.sh \
  scripts/onlyoffice-entrypoint.sh scripts/generate-proxy-config.sh scripts/configure-synapse.py; do
  [[ -e "$INSTALL_PATH/$file" ]] || install -m 0644 "$SCRIPT_DIR/$file" "$INSTALL_PATH/$file"
done
chmod 0750 "$INSTALL_PATH"/scripts/*.sh
for name in postgres_superuser_password keycloak_db_password openwehr_db_password synapse_db_password \
  keycloak_admin_password onlyoffice_jwt_secret; do
  if [[ ! -e "$INSTALL_PATH/secrets/$name" ]]; then
    openssl rand -hex 32 > "$INSTALL_PATH/secrets/$name"
    chmod 0600 "$INSTALL_PATH/secrets/$name"
  fi
done
if [[ ! -e "$INSTALL_PATH/secrets/openwehr_app_key" ]]; then
  printf 'base64:%s\n' "$(openssl rand -base64 32 | tr -d '\n')" > "$INSTALL_PATH/secrets/openwehr_app_key"
  chmod 0600 "$INSTALL_PATH/secrets/openwehr_app_key"
fi
if [[ ! -e "$INSTALL_PATH/secrets/mail_smtp_password" ]]; then
  : > "$INSTALL_PATH/secrets/mail_smtp_password"
  chmod 0600 "$INSTALL_PATH/secrets/mail_smtp_password"
fi
for entry in "postgres/data:70:70" "matrix/data:991:991" "keycloak/providers:1000:1000" \
  "keycloak/themes:1000:1000" "openwehr/storage:1000:1000" "openwehr/uploads:1000:1000" "grav/config:1000:1000"; do
  dir=${entry%%:*}
  owner=${entry#*:}
  uid=${owner%%:*}
  gid=${owner##*:}
  if [[ -z "$(find "$INSTALL_PATH/$dir" -mindepth 1 -print -quit)" ]]; then
    chown "$uid:$gid" "$INSTALL_PATH/$dir"
  fi
done
touch "$INSTALL_PATH/traefik/acme/acme.json"
chmod 0600 "$INSTALL_PATH/traefik/acme/acme.json"
if [[ -n "$DNS_ENV_FILE" && ! -e "$INSTALL_PATH/secrets/dns.env" ]]; then
  install -m 0600 "$DNS_ENV_FILE" "$INSTALL_PATH/secrets/dns.env"
fi
if [[ -n "${enabled[openwehr]:-}" && ! -f "$INSTALL_PATH/openwehr/source/Dockerfile" ]]; then
  if [[ -n "$OPENWEHR_SOURCE" ]]; then
    tar -C "$OPENWEHR_SOURCE" --exclude='./.git' --exclude='./.env' -cf - . |
      tar -C "$INSTALL_PATH/openwehr/source" -xf -
  else
    command -v git >/dev/null || fail "Git is required to fetch the pinned OpenWehr source"
    git -C "$INSTALL_PATH/openwehr/source" init -q
    git -C "$INSTALL_PATH/openwehr/source" fetch --depth 1 \
      https://github.com/roberteinsle/openwehr.git 8841840042be95ccd6d794067d8dd1f05b30b67c
    git -C "$INSTALL_PATH/openwehr/source" checkout --detach -q FETCH_HEAD
    rm -rf -- "$INSTALL_PATH/openwehr/source/.git"
  fi
fi

write_env() {
  local tmp
  tmp=$(mktemp "$INSTALL_PATH/.env.XXXXXX")
  {
    printf 'STACK_ROOT=%s\nCOMPOSE_PROFILES=%s\nPROXY_MODE=%s\nTRAEFIK_NETWORK=%s\n' \
      "$INSTALL_PATH" "$profiles" "${values[PROXY_MODE]}" "${values[TRAEFIK_NETWORK]}"
    printf 'ENABLE_PROXY_ROUTES=%s\nTRAEFIK_CERT_RESOLVER=%s\nBASE_DOMAIN=%s\nACME_EMAIL=%s\n' \
      "${values[ENABLE_PROXY_ROUTES]}" "${values[TRAEFIK_CERT_RESOLVER]:-feuerwehr}" \
      "${values[BASE_DOMAIN]}" "${values[ACME_EMAIL]}"
    printf 'ACME_CHALLENGE=%s\nACME_DNS_PROVIDER=%s\n' "${values[ACME_CHALLENGE]}" "${values[ACME_DNS_PROVIDER]}"
    printf 'ENABLED_APPS=%s\nMATRIX_FEDERATION=%s\nMATRIX_SERVER_NAME=%s\n' \
      "${values[ENABLED_APPS]}" "${values[MATRIX_FEDERATION]}" "${values[MATRIX_SERVER_NAME]}"
    for key in KEYCLOAK_HOST OPENWEHR_HOST MATRIX_HOST ELEMENT_HOST ONLYOFFICE_HOST GRAV_HOST KEYCLOAK_ADMIN_USER; do
      printf '%s=%s\n' "$key" "${values[$key]}"
    done
    printf 'VPN_BACKEND_IP=%s\n' "${values[VPN_BACKEND_IP]}"
    printf 'MAIL_MAILER=smtp\nMAIL_HOST=%s\nMAIL_PORT=%s\nMAIL_USERNAME=%s\nMAIL_ENCRYPTION=%s\n' \
      "${values[MAIL_HOST]}" "${values[MAIL_PORT]}" "${values[MAIL_USERNAME]}" "${values[MAIL_ENCRYPTION]}"
    printf 'MAIL_FROM_ADDRESS=%s\nMAIL_FROM_NAME=%s\n' "${values[MAIL_FROM_ADDRESS]}" "${values[MAIL_FROM_NAME]}"
    for key in KEYCLOAK_PORT OPENWEHR_PORT MATRIX_PORT ELEMENT_PORT ONLYOFFICE_PORT GRAV_PORT; do
      printf '%s=%s\n' "$key" "${values[$key]}"
    done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$INSTALL_PATH/.env"
}
write_env

if [[ ! -e "$INSTALL_PATH/element/config.json" ]]; then
  cat > "$INSTALL_PATH/element/config.json" <<EOF
{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "https://${values[MATRIX_HOST]}",
      "server_name": "${values[MATRIX_SERVER_NAME]}"
    }
  },
  "disable_custom_urls": true,
  "disable_guests": true,
  "brand": "Feuerwehr"
}
EOF
  chmod 0640 "$INSTALL_PATH/element/config.json"
fi

if [[ "${values[PROXY_MODE]}" == own || "${values[PROXY_MODE]}" == same-host ]]; then
  "$INSTALL_PATH/scripts/generate-proxy-config.sh" "$INSTALL_PATH" "${values[ENABLED_APPS]}" \
    "${values[PROXY_MODE]}" "${values[ENABLE_PROXY_ROUTES]}" "${values[TRAEFIK_CERT_RESOLVER]:-feuerwehr}" \
    "${values[TRAEFIK_NETWORK]}" "${values[ACME_CHALLENGE]}" "${values[ACME_DNS_PROVIDER]}"
else
  "$INSTALL_PATH/scripts/generate-proxy-config.sh" "$INSTALL_PATH" "${values[ENABLED_APPS]}" \
    remote "${values[ENABLE_PROXY_ROUTES]}" "" "" http ""
fi

compose=(docker compose --project-directory "$INSTALL_PATH" -f "$INSTALL_PATH/compose.yml")
[[ ! -f "$INSTALL_PATH/compose.proxy.yml" ]] || compose+=(-f "$INSTALL_PATH/compose.proxy.yml")
[[ ! -f "$INSTALL_PATH/compose.remote.yml" ]] || compose+=(-f "$INSTALL_PATH/compose.remote.yml")
"${compose[@]}" config --quiet
if [[ "$NO_START" != true ]]; then
  if [[ -n "${enabled[matrix]:-}" && ! -f "$INSTALL_PATH/matrix/data/homeserver.yaml" ]]; then
    "${compose[@]}" run --rm --no-deps synapse generate
    "${compose[@]}" run --rm --no-deps --entrypoint python synapse /stack/configure_synapse.py
  fi
  "${compose[@]}" up -d
  info "Stack started. Check service health: $INSTALL_PATH/scripts/healthcheck.sh"
else
  info "Files prepared. Review $INSTALL_PATH/.env, then use the documented start command."
fi
