#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DEFAULT_PATH=/srv/apps/feuerwehr
INSTALL_PATH=$DEFAULT_PATH
CONFIG_FILE=
DNS_ENV_FILE=
DRY_RUN=false
NO_START=false
ASSUME_YES=false
PATH_EXPLICIT=false
declare -A values=()
declare -A supplied=()
declare -A allowed=()

usage() {
  cat <<'EOF'
Aufruf: sudo ./install.sh [Optionen]

Ohne Konfigurationsdatei fuehrt der Installer durch die benoetigten Eingaben.
Enter uebernimmt Vorgaben in [Klammern]. Kennwoerter werden nicht ausgegeben.

Optionen:
  --path PFAD              Installationspfad (Standard: /srv/apps/feuerwehr)
  --config DATEI           KEY=VALUE-Konfiguration lesen (kein Shell-Code)
  --dns-env-file DATEI     Geschuetzte DNS-Provider-Zugangsdaten uebernehmen
  --dry-run                Nur pruefen und Vorschau zeigen; keine Aenderungen
  --no-start               Dateien vorbereiten; Dienste und Einrichtung nicht starten
  --yes                    Nur die abschliessende Bestaetigung ueberspringen
  -h, --help               Diese Hilfe anzeigen

Nach erfolgreichem Lauf: Browseradressen und Zugangshinweise in installation-info.txt.

Konfigurationsschluessel: INSTALL_PATH, BASE_DOMAIN, ACME_EMAIL, PROXY_MODE, ENABLED_APPS,
ENABLE_PROXY_ROUTES, TRAEFIK_NETWORK, TRAEFIK_CERT_RESOLVER, DEPLOY_MODE, TRAEFIK_MIDDLEWARES, STACK_MAX_MEMORY_MB, STACK_MAX_CPUS, ACME_CHALLENGE,
ACME_DNS_PROVIDER, ACME_DNS_ENV_FILE, MATRIX_SERVER_NAME, MATRIX_FEDERATION,
VPN_BACKEND_IP, KEYCLOAK_HOST, WEHRPORTAL_HOST, WEHRPORTAL_IMAGE_TAG, POSTGRES_IMAGE, MATRIX_HOST, FLUFFYCHAT_HOST,
ONLYOFFICE_HOST, DRUPAL_HOST, DRUPAL_ADMIN_EMAIL, KEYCLOAK_REALM, KEYCLOAK_ADMIN_USER, MAIL_HOST,
MAIL_PORT, MAIL_USERNAME, MAIL_ENCRYPTION, MAIL_FROM_ADDRESS, MAIL_FROM_NAME,
KEYCLOAK_PORT, WEHRPORTAL_PORT, MATRIX_PORT, FLUFFYCHAT_PORT, ONLYOFFICE_PORT,
DRUPAL_PORT, WEHRPORTAL_ADMIN_EMAILS, WEHRPORTAL_OIDC_FORCE_DISABLED.
EOF
}

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }

while (($#)); do
  case "$1" in
    --path) (($# >= 2)) || fail "--path requires a value"; INSTALL_PATH=$2; PATH_EXPLICIT=true; shift 2 ;;
    --config) (($# >= 2)) || fail "--config requires a file"; CONFIG_FILE=$2; shift 2 ;;
    --dns-env-file) (($# >= 2)) || fail "--dns-env-file requires a file"; DNS_ENV_FILE=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --no-start) NO_START=true; shift ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
done

for key in INSTALL_PATH BASE_DOMAIN ACME_EMAIL PROXY_MODE ENABLED_APPS ENABLE_PROXY_ROUTES \
  DEPLOY_MODE TRAEFIK_NETWORK TRAEFIK_CERT_RESOLVER TRAEFIK_MIDDLEWARES STACK_MAX_MEMORY_MB STACK_MAX_CPUS ACME_CHALLENGE ACME_DNS_PROVIDER ACME_DNS_ENV_FILE \
  MATRIX_SERVER_NAME MATRIX_FEDERATION VPN_BACKEND_IP KEYCLOAK_HOST WEHRPORTAL_HOST WEHRPORTAL_IMAGE_TAG POSTGRES_IMAGE MATRIX_HOST \
  ELEMENT_HOST FLUFFYCHAT_HOST ONLYOFFICE_HOST DRUPAL_HOST DRUPAL_ADMIN_EMAIL KEYCLOAK_REALM KEYCLOAK_ADMIN_USER MAIL_HOST MAIL_PORT \
  MAIL_USERNAME MAIL_ENCRYPTION MAIL_FROM_ADDRESS MAIL_FROM_NAME KEYCLOAK_PORT WEHRPORTAL_PORT \
  MATRIX_PORT ELEMENT_PORT FLUFFYCHAT_PORT ONLYOFFICE_PORT DRUPAL_PORT WEHRPORTAL_ADMIN_EMAILS WEHRPORTAL_OIDC_FORCE_DISABLED; do
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
  if [[ -z "${supplied[INSTALL_PATH]:-}" && ! -f "$INSTALL_PATH/.env" ]] && command -v docker >/dev/null 2>&1; then
    detected=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' \
      $(docker ps -aq --filter label=com.docker.compose.project=feuerwehr 2>/dev/null | head -n1) 2>/dev/null | head -n1 || true)
    if [[ "$detected" == /* && -f "$detected/.env" ]]; then
      INSTALL_PATH=$detected
    fi
  fi
  if [[ -z "$CONFIG_FILE" && -t 0 && "$DRY_RUN" == false ]]; then
    read -r -p "Installationspfad [$INSTALL_PATH]: " answer || fail "Eingabe abgebrochen."
    INSTALL_PATH=${answer:-$INSTALL_PATH}
  fi
fi
[[ "$INSTALL_PATH" == /* && "$INSTALL_PATH" != / ]] || fail "Installation path must be absolute and not /"
INSTALL_PATH="$(realpath -m -- "$INSTALL_PATH")"
[[ "$INSTALL_PATH" != / && "$INSTALL_PATH" != *$'\n'* ]] || fail "Invalid installation path"
[[ "$INSTALL_PATH" =~ ^/[A-Za-z0-9/._\ -]+$ ]] ||
  fail "Installation path may contain only letters, digits, slash, dot, underscore, hyphen, and spaces"
[[ ! -e "$INSTALL_PATH" || -d "$INSTALL_PATH" ]] || fail "Installation path exists and is not a directory"
[[ ! -L "$INSTALL_PATH/.env" ]] || fail "Refusing a symlinked stack .env"
for name in secrets postgres keycloak wehrportal matrix fluffychat onlyoffice drupal traefik backups logs integrations scripts; do
  [[ ! -L "$INSTALL_PATH/$name" ]] || fail "Refusing symlinked installation directory: $INSTALL_PATH/$name"
done

if [[ -f "$INSTALL_PATH/.env" ]] &&
    grep -Eq '^(OPENWEHR_|(ENABLED_APPS|COMPOSE_PROFILES)=([^,]+,)*openwehr(,|$))' "$INSTALL_PATH/.env"; then
  fail "This path contains an OpenWehr installation. WehrPortal is a fresh installation; use a separate empty path and retain the old data for rollback."
fi
if [[ -f "$INSTALL_PATH/.env" ]]; then
  info "Bestehende Installation erkannt: $INSTALL_PATH – Konfiguration aus .env wird übernommen."
  declare -A explicit=()
  for key in "${!supplied[@]}"; do explicit["$key"]=${supplied[$key]}; done
  read_config "$INSTALL_PATH/.env"
  # Values from --config win over the existing .env
  for key in "${!explicit[@]}"; do supplied["$key"]=${explicit[$key]}; done
  unset explicit
fi
for key in "${!supplied[@]}"; do values["$key"]=${supplied[$key]}; done
if [[ -z "${values[FLUFFYCHAT_HOST]:-}" && -n "${values[ELEMENT_HOST]:-}" ]]; then
  values[FLUFFYCHAT_HOST]=${values[ELEMENT_HOST]}
fi
if [[ -z "${values[FLUFFYCHAT_PORT]:-}" && -n "${values[ELEMENT_PORT]:-}" ]]; then
  values[FLUFFYCHAT_PORT]=${values[ELEMENT_PORT]}
fi

prompt() {
  local key=$1 prompt_text=$2 default=$3 answer address valid
  local -a addresses
  [[ -v "values[$key]" ]] && return
  if [[ -t 0 && "$DRY_RUN" == false ]]; then
    while true; do
      read -r -p "$prompt_text [$default]: " answer || fail "Eingabe abgebrochen."
      answer=${answer:-$default}
      case "$key" in
        DEPLOY_MODE) [[ "$answer" == compose || "$answer" == swarm ]] ;;
        PROXY_MODE) [[ "$answer" =~ ^(own|same-host|remote)$ ]] ;;
        ENABLE_PROXY_ROUTES|MATRIX_FEDERATION)
          case "${answer,,}" in
            j|ja|y|yes|true) answer=true ;;
            n|nein|no|false) answer=false ;;
          esac
          [[ "$answer" == true || "$answer" == false ]] ;;
        ACME_CHALLENGE) [[ "$answer" == http || "$answer" == dns ]] ;;
        MAIL_ENCRYPTION)
          [[ "$answer" != - ]] || answer=
          [[ "$answer" =~ ^(tls|ssl|)$ ]] ;;
        BASE_DOMAIN|MATRIX_SERVER_NAME) valid_domain "$answer" ;;
        VPN_BACKEND_IP) valid_private_ipv4 "$answer" ;;
        ACME_EMAIL|DRUPAL_ADMIN_EMAIL|MAIL_FROM_ADDRESS)
          [[ "$answer" =~ ^[^[:space:]@,]+@[^[:space:]@,]+\.[^[:space:]@,]+$ ]] ;;
        KEYCLOAK_REALM) [[ "$answer" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ && "$answer" != master ]] ;;
        KEYCLOAK_ADMIN_USER) [[ "$answer" =~ ^[A-Za-z0-9._-]{1,64}$ ]] ;;
        WEHRPORTAL_ADMIN_EMAILS)
          answer=${answer//[[:space:]]/}
          valid=true
          IFS=',' read -r -a addresses <<< "$answer"
          [[ -n "$answer" && "$answer" != *, && "$answer" != ,* ]] || valid=false
          for address in "${addresses[@]}"; do
            [[ "$address" =~ ^[^[:space:]@,]+@[^[:space:]@,]+\.[^[:space:]@,]+$ ]] || valid=false
          done
          [[ "$valid" == true ]] ;;
        MAIL_HOST) [[ "$answer" =~ ^[A-Za-z0-9.-]+$ ]] ;;
        MAIL_USERNAME) [[ -z "$answer" || "$answer" =~ ^[A-Za-z0-9@._+-]+$ ]] ;;
        MAIL_FROM_NAME) [[ "$answer" =~ ^[A-Za-z0-9\ _.-]{1,64}$ ]] ;;
        POSTGRES_IMAGE) [[ "$answer" =~ ^[A-Za-z0-9._:/@-]+$ ]] ;;
        TRAEFIK_NETWORK) [[ -z "$answer" || "$answer" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ;;
        TRAEFIK_CERT_RESOLVER) [[ -z "$answer" || "$answer" =~ ^[A-Za-z0-9_-]+$ ]] ;;
        MAIL_PORT) [[ "$answer" =~ ^[0-9]{1,5}$ ]] && ((10#$answer >= 1 && 10#$answer <= 65535)) ;;
        *_PORT) [[ "$answer" =~ ^[0-9]{1,5}$ ]] && ((10#$answer >= 1024 && 10#$answer <= 65535)) ;;
        STACK_MAX_MEMORY_MB) [[ "$answer" =~ ^[0-9]{4,8}$ ]] && ((10#$answer >= 4096)) ;;
        STACK_MAX_CPUS) [[ "$answer" =~ ^[0-9]+(\.[0-9]+)?$ ]] && awk -v c="$answer" 'BEGIN {exit !(c >= 1)}' ;;
        *) true ;;
      esac && break
      printf 'Ungueltige Eingabe fuer %s. Bitte den angegebenen Wertebereich verwenden und erneut versuchen.\n' "$key" >&2
    done
    values["$key"]=$answer
  else
    values["$key"]=$default
  fi
}
select_apps() {
  local app label default answer selected=
  [[ -v "values[ENABLED_APPS]" ]] && return
  if [[ -t 0 && "$DRY_RUN" == false ]]; then
    for app in keycloak wehrportal matrix onlyoffice drupal; do
      case "$app" in
        keycloak) label=Keycloak; default=j ;;
        wehrportal) label=WehrPortal; default=j ;;
        matrix) label="Matrix Synapse und FluffyChat"; default=n ;;
        onlyoffice) label=ONLYOFFICE; default=n ;;
        drupal) label="Drupal Website"; default=n ;;
      esac
      while true; do
        if [[ "$default" == j ]]; then
          read -r -p "$label installieren? [J/n] " answer || fail "Eingabe abgebrochen."
        else
          read -r -p "$label installieren? [j/N] " answer || fail "Eingabe abgebrochen."
        fi
        answer=${answer:-$default}
        case "$answer" in
          j|J|ja|JA|y|Y|yes|YES) selected+="${selected:+,}$app"; break ;;
          n|N|nein|NEIN|no|NO) break ;;
          *) printf 'Bitte mit ja oder nein antworten.\n' >&2 ;;
        esac
      done
    done
    values[ENABLED_APPS]=$selected
  else
    values[ENABLED_APPS]=keycloak,wehrportal
  fi
}
prompt_dns_host() {
  local key=$1 label=$2 default=$3 answer
  [[ -v "values[$key]" ]] && return
  answer=$default
  if [[ -n "${enabled[$app_for_dns_prompt]:-}" && -t 0 && "$DRY_RUN" == false ]]; then
    while true; do
      read -r -p "$label DNS-Subdomain unter ${values[BASE_DOMAIN]} [$default]: " answer || fail "Eingabe abgebrochen."
      answer=${answer:-$default}
      [[ "$answer" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] && break
      printf 'Bitte nur das Subdomain-Label eingeben, z.B. %s (keine URL oder vollstaendige Domain).\n' "$default" >&2
    done
  fi
  values["$key"]="${answer}.${values[BASE_DOMAIN]}"
}
require_value() {
  local key=$1 prompt_text=$2 answer
  [[ -n "${values[$key]}" ]] && return
  if [[ -t 0 && "$DRY_RUN" == false ]]; then
    while [[ -z "${values[$key]}" ]]; do
      read -r -p "$prompt_text: " answer || fail "Eingabe abgebrochen."
      values["$key"]=$answer
      [[ -n "$answer" ]] || printf 'Dieses Feld ist erforderlich. Bitte einen Wert eingeben.\n' >&2
    done
  fi
  [[ -n "${values[$key]}" ]] || fail "$key is required for the selected installation mode"
}

valid_domain() {
  [[ ${#1} -le 253 && "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}
valid_private_ipv4() {
  local address=$1 octet a b
  local -a octets
  [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$address"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
  a=$((10#${octets[0]}))
  b=$((10#${octets[1]}))
  [[ "$a" -eq 10 || ("$a" -eq 172 && "$b" -ge 16 && "$b" -le 31) ||
     ("$a" -eq 192 && "$b" -eq 168) || ("$a" -eq 100 && "$b" -ge 64 && "$b" -le 127) ]]
}
prompt_for_app() {
  local app=$1 key=$2
  shift 2
  if [[ -n "${enabled[$app]:-}" ]]; then
    prompt "$key" "$@"
  else
    values["$key"]=${values[$key]-$2}
  fi
}

info "Feuerwehr-Stack: gefuehrte Einrichtung"
info "Enter uebernimmt den Wert in [Klammern]. Mit Strg+C koennen Sie abbrechen."
info "Vor der abschliessenden Bestaetigung werden keine Installationsdateien veraendert."
prompt BASE_DOMAIN "Primaere Domain, z.B. feuerwehr.example.de (ohne https://)" feuerwehr.example.de
select_apps
IFS=',' read -r -a apps <<< "${values[ENABLED_APPS]}"
declare -A enabled=()
for app in "${apps[@]}"; do
  case "$app" in keycloak|wehrportal|matrix|onlyoffice|drupal) ;; *) fail "Unknown application: $app";; esac
  [[ -z "${enabled[$app]:-}" ]] || fail "Duplicate application: $app"
  enabled["$app"]=1
done
[[ ${#enabled[@]} -gt 0 ]] || fail "Select at least one application"
swarm_manager=false
if command -v docker >/dev/null &&
   [[ "$(docker info --format '{{.Swarm.ControlAvailable}}' 2>/dev/null || true)" == true ]]; then
  swarm_manager=true
fi
# Existing installations keep their mode; only fresh installs on a Swarm manager default to swarm.
default_deploy=compose
if [[ "$swarm_manager" == true && ! -f "$INSTALL_PATH/.env" ]]; then default_deploy=swarm; fi
prompt DEPLOY_MODE "Bereitstellung (compose = Docker Compose, swarm = Docker-Swarm-Stack)" "$default_deploy"
case "${values[DEPLOY_MODE]}" in compose|swarm) ;; *) fail "DEPLOY_MODE must be compose or swarm" ;; esac
default_proxy=own
[[ "${values[DEPLOY_MODE]}" != swarm ]] || default_proxy=same-host
info "Proxy-Modi: own = neuer Traefik auf diesem Host; same-host = vorhandener Traefik; remote = entfernter Proxy ueber VPN."
prompt PROXY_MODE "Reverse-Proxy-Modus (own/same-host/remote)" "$default_proxy"
if [[ "${values[PROXY_MODE]}" == own ]]; then
  prompt ACME_EMAIL "Let's Encrypt E-Mail-Adresse (Zertifikatsmeldungen)" "admin@${values[BASE_DOMAIN]}"
fi
values[ACME_EMAIL]=${values[ACME_EMAIL]:-admin@${values[BASE_DOMAIN]}}
prompt ENABLE_PROXY_ROUTES "Proxy-Routen aktivieren (true/false)" true
if [[ "${values[PROXY_MODE]}" == same-host ]]; then
  prompt TRAEFIK_NETWORK "Vorhandenes Traefik-Docker-Netzwerk" ""
  prompt TRAEFIK_CERT_RESOLVER "Zertifikatsresolver des vorhandenen Traefik" ""
fi
values[TRAEFIK_NETWORK]=${values[TRAEFIK_NETWORK]:-}
values[TRAEFIK_CERT_RESOLVER]=${values[TRAEFIK_CERT_RESOLVER]:-}
values[TRAEFIK_MIDDLEWARES]=${values[TRAEFIK_MIDDLEWARES]:-}
if [[ "${values[PROXY_MODE]}" == own ]]; then
  prompt ACME_CHALLENGE "TLS-Nachweis (http = Port 80 erreichbar; dns = DNS-Provider-Zugang)" http
fi
values[ACME_CHALLENGE]=${values[ACME_CHALLENGE]:-http}
if [[ "${values[PROXY_MODE]}" == own && "${values[ACME_CHALLENGE]}" == dns ]]; then
  prompt ACME_DNS_PROVIDER "Traefik DNS-Provider (nur DNS-01)" ""
  prompt ACME_DNS_ENV_FILE "Provider-Variablen-Datei fuer DNS-01" ""
fi
values[ACME_DNS_PROVIDER]=${values[ACME_DNS_PROVIDER]:-}
values[ACME_DNS_ENV_FILE]=${values[ACME_DNS_ENV_FILE]:-}
prompt_for_app matrix MATRIX_FEDERATION "Matrix Federation: Kommunikation mit anderen Servern (ja/nein)" false
if [[ "${values[PROXY_MODE]}" == remote ]]; then
  prompt VPN_BACKEND_IP "Private VPN-IPv4-Adresse des Backend-Hosts (z.B. 10.20.0.5)" ""
fi
values[VPN_BACKEND_IP]=${values[VPN_BACKEND_IP]:-}
prompt_for_app keycloak KEYCLOAK_ADMIN_USER "Initialer Keycloak-Administrator" kcadmin
prompt_for_app wehrportal WEHRPORTAL_ADMIN_EMAILS "Initiale WehrPortal-Administrator-E-Mail(s), kommagetrennt" ""
prompt_for_app wehrportal WEHRPORTAL_IMAGE_TAG "WehrPortal Image-Tag" latest
prompt POSTGRES_IMAGE "PostgreSQL Image" postgres:latest
values[WEHRPORTAL_IMAGE_TAG]=${values[WEHRPORTAL_IMAGE_TAG]:-latest}
values[POSTGRES_IMAGE]=${values[POSTGRES_IMAGE]:-postgres:latest}
if [[ -n "${enabled[wehrportal]:-}" ]]; then
  info "WehrPortal versendet Anmeldelinks per E-Mail. Halten Sie die SMTP-Daten Ihres Mailanbieters bereit."
fi
prompt_for_app wehrportal MAIL_HOST "SMTP-Server fuer WehrPortal (Magic-Link-Anmeldung)" ""
prompt_for_app wehrportal MAIL_PORT "SMTP-Port" 587
prompt_for_app wehrportal MAIL_USERNAME "SMTP-Benutzername (leer bei Versand ohne Anmeldung)" ""
prompt_for_app wehrportal MAIL_ENCRYPTION "SMTP-Verschluesselung (tls/ssl; '-' = unverschluesselt)" tls
prompt_for_app wehrportal MAIL_FROM_ADDRESS "Absenderadresse fuer WehrPortal" ""
prompt_for_app wehrportal MAIL_FROM_NAME "Absendername fuer WehrPortal" Feuerwehr
smtp_password=
if [[ -n "${enabled[wehrportal]:-}" && -n "${values[MAIL_USERNAME]}" && -t 0 && "$DRY_RUN" == false ]]; then
  read -r -s -p "SMTP-Passwort (Eingabe unsichtbar, leer = vorhandenes behalten) []: " smtp_password || fail "Eingabe abgebrochen."
  printf '\n'
fi

host_mem_mb=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true)
host_mem_mb=${host_mem_mb:-8192}
default_mem_mb=$((host_mem_mb - 1024))
((default_mem_mb >= 4096)) || default_mem_mb=4096
default_cpus=$(nproc 2>/dev/null || echo 4)
prompt STACK_MAX_MEMORY_MB "Maximaler Arbeitsspeicher für den gesamten Stack in MB (Host: ${host_mem_mb} MB)" "$default_mem_mb"
prompt STACK_MAX_CPUS "Maximal nutzbare CPU-Kerne für den gesamten Stack (Host: ${default_cpus})" "$default_cpus"

values[DRUPAL_OIDC_ENABLED]=false
values[WEHRPORTAL_OIDC_ENABLED]=false
values[MATRIX_OIDC_ENABLED]=false
values[WEHRPORTAL_OIDC_FORCE_DISABLED]=${values[WEHRPORTAL_OIDC_FORCE_DISABLED]:-false}
[[ "${values[WEHRPORTAL_OIDC_FORCE_DISABLED]}" == true || "${values[WEHRPORTAL_OIDC_FORCE_DISABLED]}" == false ]] ||
  fail "WEHRPORTAL_OIDC_FORCE_DISABLED must be true or false"
if [[ -n "${enabled[wehrportal]:-}" && -n "${enabled[keycloak]:-}" ]]; then
  values[WEHRPORTAL_OIDC_ENABLED]=true
  command -v python3 >/dev/null || fail "python3 is required for Keycloak provisioning"
fi
if [[ -n "${enabled[matrix]:-}" && -n "${enabled[keycloak]:-}" ]]; then
  values[MATRIX_OIDC_ENABLED]=true
  command -v python3 >/dev/null || fail "python3 is required for Keycloak provisioning"
fi
if [[ -n "${enabled[keycloak]:-}" ]]; then
  prompt KEYCLOAK_REALM "Keycloak Realm-Name" feuerwehr
else
  values[KEYCLOAK_REALM]=${values[KEYCLOAK_REALM]:-feuerwehr}
fi
[[ "${values[KEYCLOAK_REALM]}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ &&
   "${values[KEYCLOAK_REALM]}" != master ]] || fail "KEYCLOAK_REALM must be a dedicated realm name (not master)"
if [[ -n "${enabled[drupal]:-}" ]]; then
  prompt DRUPAL_ADMIN_EMAIL "E-Mail-Adresse des lokalen Drupal-Notfalladministrators" "admin@${values[BASE_DOMAIN]}"
  [[ "${values[DRUPAL_ADMIN_EMAIL]}" =~ ^[^[:space:]@,]+@[^[:space:]@,]+\.[^[:space:]@,]+$ ]] ||
    fail "Invalid DRUPAL_ADMIN_EMAIL"
  command -v python3 >/dev/null || fail "python3 is required for Drupal and Keycloak provisioning"
  [[ -z "${enabled[keycloak]:-}" ]] || values[DRUPAL_OIDC_ENABLED]=true
else
  values[DRUPAL_ADMIN_EMAIL]=${values[DRUPAL_ADMIN_EMAIL]:-admin@${values[BASE_DOMAIN]}}
fi

[[ "${values[STACK_MAX_MEMORY_MB]}" =~ ^[0-9]+$ ]] && ((10#${values[STACK_MAX_MEMORY_MB]} >= 4096)) ||
  fail "STACK_MAX_MEMORY_MB must be an integer of at least 4096"
[[ "${values[STACK_MAX_CPUS]}" =~ ^[0-9]+(\.[0-9]+)?$ ]] &&
  awk -v c="${values[STACK_MAX_CPUS]}" 'BEGIN {exit !(c >= 1)}' ||
  fail "STACK_MAX_CPUS must be a number of at least 1"
if [[ -n "${enabled[onlyoffice]:-}" ]] && ((10#${values[STACK_MAX_MEMORY_MB]} < 8192)); then
  printf 'WARN: ONLYOFFICE benötigt für den Normalbetrieb mindestens 8192 MB Stack-Speicher\n' >&2
fi
if ((10#${values[STACK_MAX_MEMORY_MB]} > host_mem_mb)); then
  printf 'WARN: STACK_MAX_MEMORY_MB (%s) übersteigt den Host-Speicher (%s MB)\n' \
    "${values[STACK_MAX_MEMORY_MB]}" "$host_mem_mb" >&2
fi

# Per-service ceilings share the budget by weight; name:memory weight:memory floor:cpu share
declare -A limit_mem=() limit_cpu=()
limit_services=(postgres:1024:512:0.50 redis:256:128:0.25)
[[ -z "${enabled[keycloak]:-}" ]] || limit_services+=(keycloak:1024:768:0.50)
[[ -z "${enabled[wehrportal]:-}" ]] || limit_services+=(wehrportal:768:512:0.50 wehrportal_worker:384:256:0.25)
[[ -z "${enabled[matrix]:-}" ]] || limit_services+=(synapse:1024:512:0.50 fluffychat:128:64:0.15)
[[ -z "${enabled[onlyoffice]:-}" ]] || limit_services+=(onlyoffice:3072:2048:0.75)
[[ -z "${enabled[drupal]:-}" ]] || limit_services+=(drupal:768:512:0.50)
[[ "${values[PROXY_MODE]}" != own ]] || limit_services+=(traefik:256:128:0.25)
total_weight=0
for entry in "${limit_services[@]}"; do
  IFS=: read -r _ weight _ _ <<< "$entry"
  total_weight=$((total_weight + weight))
done
for entry in "${limit_services[@]}"; do
  IFS=: read -r name weight floor share <<< "$entry"
  mem=$((10#${values[STACK_MAX_MEMORY_MB]} * weight / total_weight))
  ((mem >= floor)) || mem=$floor
  limit_mem[$name]="${mem}m"
  limit_cpu[$name]=$(awk -v t="${values[STACK_MAX_CPUS]}" -v s="$share" \
    'BEGIN {c = t * s; if (c < 0.25) c = 0.25; if (c > t) c = t; printf "%.2f", c}')
done

app_for_dns_prompt=keycloak
prompt_dns_host KEYCLOAK_HOST "Keycloak (login)" login
app_for_dns_prompt=wehrportal
prompt_dns_host WEHRPORTAL_HOST "WehrPortal (portal)" portal
app_for_dns_prompt=matrix
prompt_dns_host MATRIX_HOST "Matrix Server" matrix
prompt_dns_host FLUFFYCHAT_HOST "Matrix Web-Messenger" messenger
app_for_dns_prompt=onlyoffice
prompt_dns_host ONLYOFFICE_HOST "ONLYOFFICE" docs
app_for_dns_prompt=drupal
prompt_dns_host DRUPAL_HOST "Website" www
prompt_for_app matrix MATRIX_SERVER_NAME "Matrix-Identitaetsdomain (nach Nutzung nicht aendern)" "${values[MATRIX_HOST]}"

if [[ "${values[PROXY_MODE]}" == same-host ]]; then
  require_value TRAEFIK_NETWORK "Name des bereits vorhandenen Traefik-Docker-Netzwerks"
  [[ "${values[ENABLE_PROXY_ROUTES]}" != true ]] ||
    require_value TRAEFIK_CERT_RESOLVER "Zertifikatsresolver des vorhandenen Traefik"
fi
if [[ "${values[PROXY_MODE]}" == remote ]]; then
  require_value VPN_BACKEND_IP "Private VPN-IPv4-Adresse dieses Backend-Hosts"
fi
if [[ "${values[PROXY_MODE]}" == own && "${values[ACME_CHALLENGE]}" == dns ]]; then
  require_value ACME_DNS_PROVIDER "Traefik DNS-Providerkennung"
  if [[ -z "$DNS_ENV_FILE" ]]; then
    require_value ACME_DNS_ENV_FILE "Pfad zur Datei mit DNS-Provider-Variablen"
    DNS_ENV_FILE=${values[ACME_DNS_ENV_FILE]}
  fi
fi
if [[ -n "${values[ENABLED_APPS]}" && ",${values[ENABLED_APPS]}," == *,wehrportal,* ]]; then
  require_value MAIL_HOST "SMTP-Hostname für WehrPortal"
  require_value MAIL_FROM_ADDRESS "Absenderadresse für WehrPortal"
  require_value WEHRPORTAL_ADMIN_EMAILS "Initiale WehrPortal-Administrator-E-Mail(s), kommagetrennt"
fi

for key in BASE_DOMAIN KEYCLOAK_HOST WEHRPORTAL_HOST MATRIX_HOST FLUFFYCHAT_HOST ONLYOFFICE_HOST DRUPAL_HOST MATRIX_SERVER_NAME; do
  valid_domain "${values[$key]}" || fail "Invalid domain: ${values[$key]}"
done
[[ "${values[KEYCLOAK_ADMIN_USER]}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || fail "Invalid KEYCLOAK_ADMIN_USER"
[[ "${values[POSTGRES_IMAGE]}" =~ ^[A-Za-z0-9._:/@-]+$ ]] || fail "Invalid POSTGRES_IMAGE"
[[ "${values[MAIL_HOST]}" == "" || "${values[MAIL_HOST]}" =~ ^[A-Za-z0-9.-]+$ ]] || fail "Invalid MAIL_HOST"
[[ "${values[MAIL_USERNAME]}" == "" || "${values[MAIL_USERNAME]}" =~ ^[A-Za-z0-9@._+-]+$ ]] ||
  fail "MAIL_USERNAME contains unsupported characters"
mail_from_name_re='^[A-Za-z0-9 _.-]{1,64}$'
[[ "${values[MAIL_FROM_NAME]}" =~ $mail_from_name_re ]] || fail "Invalid MAIL_FROM_NAME"
[[ "${values[MAIL_ENCRYPTION]}" =~ ^(tls|ssl|)$ ]] || fail "MAIL_ENCRYPTION must be tls, ssl, or empty"
if [[ ! "${values[MAIL_PORT]}" =~ ^[0-9]+$ ]] ||
    ((10#${values[MAIL_PORT]} < 1 || 10#${values[MAIL_PORT]} > 65535)); then
  fail "Invalid MAIL_PORT"
fi
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
[[ -z "${values[TRAEFIK_MIDDLEWARES]}" || "${values[TRAEFIK_MIDDLEWARES]}" =~ ^[A-Za-z0-9_@.,-]+$ ]] ||
  fail "Invalid TRAEFIK_MIDDLEWARES"
[[ -z "${values[TRAEFIK_CERT_RESOLVER]}" || "${values[TRAEFIK_CERT_RESOLVER]}" =~ ^[A-Za-z0-9_-]+$ ]] ||
  fail "Invalid TRAEFIK_CERT_RESOLVER"
if [[ "${values[PROXY_MODE]}" == own ]]; then
  [[ "${values[ACME_EMAIL]}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || fail "Invalid ACME_EMAIL"
fi
if [[ "${values[ACME_CHALLENGE]}" == dns ]]; then
  [[ "${values[ACME_DNS_PROVIDER]}" =~ ^[a-z0-9]+$ ]] || fail "DNS-01 requires a valid Traefik DNS provider"
  DNS_ENV_FILE=${DNS_ENV_FILE:-${values[ACME_DNS_ENV_FILE]}}
fi

if [[ "${values[PROXY_MODE]}" == remote ]]; then
  valid_private_ipv4 "${values[VPN_BACKEND_IP]}" ||
    fail "VPN_BACKEND_IP muss eine private IPv4-Adresse sein (z.B. 10.20.0.5)."
fi

for key in KEYCLOAK_PORT WEHRPORTAL_PORT MATRIX_PORT FLUFFYCHAT_PORT ONLYOFFICE_PORT DRUPAL_PORT; do
  default=18080
  case "$key" in
    KEYCLOAK_PORT) default=18084 ;;
    WEHRPORTAL_PORT) default=18080 ;;
    MATRIX_PORT) default=18008 ;;
    FLUFFYCHAT_PORT) default=18081 ;;
    ONLYOFFICE_PORT) default=18082 ;;
    DRUPAL_PORT) default=18083 ;;
  esac
  if [[ "${values[PROXY_MODE]}" == remote ]]; then
    app=${key%_PORT}
    app=${app,,}
    [[ "$app" != fluffychat ]] || app=matrix
    prompt_for_app "$app" "$key" "$key (nur im VPN erreichbar, 1024-65535)" "$default"
  else
    values["$key"]=${values[$key]-$default}
  fi
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
      wehrportal) selected_ports+=("${values[WEHRPORTAL_PORT]}") ;;
      matrix) selected_ports+=("${values[MATRIX_PORT]}" "${values[FLUFFYCHAT_PORT]}") ;;
      onlyoffice) selected_ports+=("${values[ONLYOFFICE_PORT]}") ;;
      drupal) selected_ports+=("${values[DRUPAL_PORT]}") ;;
    esac
  done
  [[ $(printf '%s\n' "${selected_ports[@]}" | sort -u | wc -l) -eq ${#selected_ports[@]} ]] ||
    fail "Remote backend ports must be unique"
fi

if [[ -n "${enabled[wehrportal]:-}" ]]; then
  existing_wehrportal=false
  if [[ -f "$INSTALL_PATH/.env" && -f "$INSTALL_PATH/secrets/wehrportal_app_key" ]] &&
      grep -Eq '^ENABLED_APPS=([^,]+,)*wehrportal(,|$)' "$INSTALL_PATH/.env" &&
      grep -Eq '^WEHRPORTAL_IMAGE_TAG=(latest|v[0-9]+\.[0-9]+(\.[0-9]+){0,2})$' "$INSTALL_PATH/.env"; then
    existing_wehrportal=true
  fi
  if [[ -f "$INSTALL_PATH/postgres/data/PG_VERSION" && "$existing_wehrportal" != true ]]; then
    fail "Existing PostgreSQL data was found at $INSTALL_PATH/postgres/data. WehrPortal does not migrate OpenWehr data; use a separate empty installation path."
  fi
  [[ -n "${values[MAIL_HOST]}" && -n "${values[MAIL_FROM_ADDRESS]}" ]] ||
    fail "WehrPortal magic-link login requires MAIL_HOST and MAIL_FROM_ADDRESS"
  [[ "${values[MAIL_FROM_ADDRESS]}" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
    fail "Invalid MAIL_FROM_ADDRESS"
  IFS=',' read -r -a admin_emails <<< "${values[WEHRPORTAL_ADMIN_EMAILS]}"
  for address in "${admin_emails[@]}"; do
    [[ "$address" =~ ^[^[:space:]@,]+@[^[:space:]@,]+\.[^[:space:]@,]+$ ]] ||
      fail "Invalid WehrPortal administrator email"
  done
fi
[[ -z "$DNS_ENV_FILE" || -r "$DNS_ENV_FILE" ]] || fail "DNS provider file is not readable"
if [[ "${values[PROXY_MODE]}" == own && "${values[ACME_CHALLENGE]}" == dns && -z "$DNS_ENV_FILE" &&
      ! -f "$INSTALL_PATH/secrets/dns.env" ]]; then
  fail "DNS-01 requires --dns-env-file or an existing $INSTALL_PATH/secrets/dns.env"
fi

resolve_wehrportal_image() {
  local tag release_url release_json
  tag=${values[WEHRPORTAL_IMAGE_TAG]:-latest}
  if [[ "$tag" == latest ]]; then
    docker manifest inspect "ghcr.io/timux/wehrportal:latest" >/dev/null 2>&1 ||
      fail "The published WehrPortal image ghcr.io/timux/wehrportal:latest is unavailable."
    values[WEHRPORTAL_IMAGE_TAG]=latest
    return
  fi
  command -v curl >/dev/null || fail "curl is required to verify the published WehrPortal release"
  command -v python3 >/dev/null || fail "python3 is required to read the published WehrPortal release metadata"
  if [[ -z "$tag" ]]; then
    release_url=https://api.github.com/repos/TimUx/WehrPortal/releases/latest
  else
    release_url="https://api.github.com/repos/TimUx/WehrPortal/releases/tags/$tag"
  fi
  release_json=$(curl --fail --silent --show-error --location \
    --header 'Accept: application/vnd.github+json' \
    --header 'X-GitHub-Api-Version: 2022-11-28' "$release_url") ||
    fail "No published WehrPortal release could be verified at $release_url; refusing to use an unverified image tag."
  tag=$(python3 -c 'import json, sys; print(json.load(sys.stdin).get("tag_name", ""))' <<< "$release_json") ||
    fail "Could not read the WehrPortal release tag from GitHub."
  [[ "$tag" =~ ^v[0-9]+\.[0-9]+(\.[0-9]+){0,2}$ ]] ||
    fail "GitHub returned an invalid WehrPortal release tag: $tag"
  docker manifest inspect "ghcr.io/timux/wehrportal:$tag" >/dev/null 2>&1 ||
    fail "The published WehrPortal image ghcr.io/timux/wehrportal:$tag is unavailable; no fallback image will be used."
  values[WEHRPORTAL_IMAGE_TAG]=$tag
}
if [[ "${values[PROXY_MODE]}" == own ]]; then
  command -v ss >/dev/null || fail "ss is required to check ports 80 and 443"
  for port in 80 443; do
    ss -H -ltn "sport = :$port" | grep -q . && fail "TCP port $port is already in use"
    if command -v docker >/dev/null && docker ps --format '{{.Ports}}' 2>/dev/null |
        grep -Eq "(^|[, ])[^,]*:${port}->"; then
      fail "A running Docker container already publishes TCP port $port"
    fi
  done
fi
if [[ "${values[DEPLOY_MODE]}" == swarm && "${values[PROXY_MODE]}" != same-host ]]; then
  fail "DEPLOY_MODE=swarm requires PROXY_MODE=same-host (Traefik reads the labels through the swarm overlay network)"
fi
if [[ "${values[DEPLOY_MODE]}" == swarm && "${values[ENABLE_PROXY_ROUTES]}" != true ]]; then
  printf 'WARN: Swarm-Modus ohne ENABLE_PROXY_ROUTES=true erzeugt keine Traefik-Labels\n' >&2
fi
if [[ "${values[PROXY_MODE]}" == same-host ]]; then
  if command -v docker >/dev/null && docker network inspect "${values[TRAEFIK_NETWORK]}" >/dev/null 2>&1; then
    if [[ "${values[DEPLOY_MODE]}" == swarm &&
          "$(docker network inspect --format '{{.Scope}}' "${values[TRAEFIK_NETWORK]}")" != swarm ]]; then
      fail "Network ${values[TRAEFIK_NETWORK]} is not a swarm overlay network (scope swarm)"
    fi
  elif [[ "$DRY_RUN" == true ]]; then
    printf 'WARN: cannot verify existing Docker network %s during dry-run\n' "${values[TRAEFIK_NETWORK]}" >&2
  else
    fail "Configured Docker network does not exist or cannot be inspected: ${values[TRAEFIK_NETWORK]}"
  fi
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
  case "${ID:-}" in debian|ubuntu) ;; *) fail "Supported operating systems: Debian and Ubuntu";; esac
  command -v docker >/dev/null || fail "Docker Engine is not installed"
  docker compose version >/dev/null 2>&1 || fail "Docker Compose v2 plugin is required"
  docker info >/dev/null 2>&1 || fail "Docker Engine is not reachable"
  if [[ "${values[DEPLOY_MODE]}" == swarm ]]; then
    [[ "$swarm_manager" == true ]] ||
      fail "DEPLOY_MODE=swarm requires a Docker Swarm manager node (docker swarm init)"
    command -v python3 >/dev/null || fail "python3 is required to build the Swarm stack file"
    if [[ -n "$(docker ps -q --filter label=com.docker.compose.project=feuerwehr 2>/dev/null)" ]]; then
      fail "Compose containers of project feuerwehr are running; stop them first (docker compose down) before switching to swarm"
    fi
  elif docker stack ls --format '{{.Name}}' 2>/dev/null | grep -qx feuerwehr; then
    fail "A Swarm stack named feuerwehr exists; remove it first (docker stack rm feuerwehr) before switching to compose"
  fi
  command -v openssl >/dev/null || fail "openssl is required to generate secrets"
  space_path=$(dirname -- "$INSTALL_PATH")
  while [[ ! -d "$space_path" ]]; do space_path=$(dirname -- "$space_path"); done
  available_kb=$(df -Pk "$space_path" | awk 'NR==2 {print $4}')
  minimum_kb=5242880
  [[ -z "${enabled[onlyoffice]:-}" ]] || minimum_kb=8388608
  (( available_kb >= minimum_kb )) || fail "At least $((minimum_kb / 1048576)) GiB free disk space is required"
fi
if [[ -n "${enabled[wehrportal]:-}" && "$DRY_RUN" == false ]]; then
  resolve_wehrportal_image
fi
if [[ "${values[ENABLE_PROXY_ROUTES]}" == true ]] && command -v getent >/dev/null; then
  for app in "${apps[@]}"; do
    case "$app" in
      keycloak) host=${values[KEYCLOAK_HOST]} ;;
      wehrportal) host=${values[WEHRPORTAL_HOST]} ;;
      matrix) host=${values[MATRIX_HOST]} ;;
      onlyoffice) host=${values[ONLYOFFICE_HOST]} ;;
      drupal) host=${values[DRUPAL_HOST]} ;;
    esac
    getent ahosts "$host" >/dev/null || printf 'WARN: DNS currently does not resolve %s\n' "$host" >&2
    if [[ "$app" == matrix ]]; then
      getent ahosts "${values[FLUFFYCHAT_HOST]}" >/dev/null ||
        printf 'WARN: DNS currently does not resolve %s\n' "${values[FLUFFYCHAT_HOST]}" >&2
    fi
  done
fi

profiles=data
for app in "${apps[@]}"; do profiles+=",${app}"; done
[[ "${values[PROXY_MODE]}" != own ]] || profiles+=",proxy"
values[STACK_ROOT]=$INSTALL_PATH
values[COMPOSE_PROFILES]=$profiles
values[ENABLED_APPS]=$(IFS=,; echo "${apps[*]}")
values[WEHRPORTAL_IMAGE_TAG]=${values[WEHRPORTAL_IMAGE_TAG]:-latest}
start_services=ja
if [[ "$DRY_RUN" == true ]]; then
  start_services='nein (nur Vorschau)'
elif [[ "$NO_START" == true ]]; then
  start_services='nein (--no-start)'
fi

cat <<EOF
=== Vorschau: geplante Installation ===
  Installationspfad: $INSTALL_PATH
  Anwendungen:      ${values[ENABLED_APPS]}
  Proxy-Modus:      ${values[PROXY_MODE]}
  Proxy-Routen:     ${values[ENABLE_PROXY_ROUTES]}
  Primaere Domain:  ${values[BASE_DOMAIN]}
  Ressourcenbudget: ${values[STACK_MAX_MEMORY_MB]} MB RAM, ${values[STACK_MAX_CPUS]} CPU-Kerne
  Bereitstellung:   ${values[DEPLOY_MODE]}
  Dienste starten:  $start_services
EOF
if [[ "${values[PROXY_MODE]}" == own ]]; then
  printf '  TLS-Nachweis: %s\n' "${values[ACME_CHALLENGE]}"
fi
if [[ -n "${enabled[keycloak]:-}" ]]; then
  printf '  DNS Keycloak (login): %s\n' "${values[KEYCLOAK_HOST]}"
  printf '  Keycloak-Realm: %s\n' "${values[KEYCLOAK_REALM]}"
fi
if [[ -n "${enabled[wehrportal]:-}" ]]; then
  printf '  DNS WehrPortal (portal): %s\n  Image: ghcr.io/timux/wehrportal:%s\n' \
    "${values[WEHRPORTAL_HOST]}" "${values[WEHRPORTAL_IMAGE_TAG]:-wird beim Installieren verifiziert}"
  printf '  WehrPortal OIDC: %s (Notfallschalter: %s)\n' "${values[WEHRPORTAL_OIDC_ENABLED]}" "${values[WEHRPORTAL_OIDC_FORCE_DISABLED]}"
fi
if [[ -n "${enabled[matrix]:-}" ]]; then
  printf '  DNS Matrix Server: %s\n  DNS Matrix Web-Messenger: %s\n' \
    "${values[MATRIX_HOST]}" "${values[FLUFFYCHAT_HOST]}"
  printf '  Matrix OIDC: %s\n' "${values[MATRIX_OIDC_ENABLED]}"
  printf '  FluffyChat:     %s\n  Matrix-Identitaetsdomain: %s (Federation: %s)\n' \
    "${values[FLUFFYCHAT_HOST]}" "${values[MATRIX_SERVER_NAME]}" "${values[MATRIX_FEDERATION]}"
fi
if [[ -n "${enabled[onlyoffice]:-}" ]]; then
  printf '  DNS ONLYOFFICE: %s\n' "${values[ONLYOFFICE_HOST]}"
  if [[ -n "${enabled[wehrportal]:-}" ]]; then
    printf '  WehrPortal Dateien: automatische ONLYOFFICE-Konfiguration\n'
  fi
fi
if [[ -n "${enabled[drupal]:-}" ]]; then
  printf '  DNS Drupal Website (www): %s\n  Drupal OIDC: %s\n' "${values[DRUPAL_HOST]}" "${values[DRUPAL_OIDC_ENABLED]}"
fi

if [[ "$DRY_RUN" == true ]]; then
  info "Vorschau abgeschlossen; keine Dateien oder Dienste wurden veraendert."
  exit 0
fi
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "Installation mit diesen Einstellungen starten? [j/N] " answer || fail "Eingabe abgebrochen."
  case "${answer,,}" in
    j|ja|y|yes) ;;
    *) info "Abgebrochen. Es wurden keine Installationsdateien veraendert."; exit 1 ;;
  esac
fi

installation_stage="Dateien und geschuetzte Zugangsdaten vorbereiten"
installation_failed() {
  local result=$?
  trap - ERR
  [[ -z "${summary_tmp:-}" ]] || rm -f -- "$summary_tmp"
  printf '\nFEHLER: Einrichtung nicht abgeschlossen (Schritt: %s).\n' "$installation_stage" >&2
  printf 'Bitte die Fehlermeldung darueber pruefen. Keine Kennwoerter oder Secrets aus Logs weitergeben.\n' >&2
  printf 'Installationspfad: %s. Vorhandene Daten und Zugangsdaten nicht loeschen.\n' "$INSTALL_PATH" >&2
  printf 'Nach Fehlerkorrektur den Installer mit denselben Einstellungen erneut aufrufen.\n' >&2
  exit "$result"
}
trap installation_failed ERR
info "[1/4] Dateien und geschuetzte Zugangsdaten vorbereiten ..."
install -d -m 0750 "$INSTALL_PATH"
install -d -m 0750 "$INSTALL_PATH"/{secrets,postgres/data,keycloak/providers,keycloak/themes,wehrportal/storage/app,matrix/data,fluffychat,onlyoffice/logs,onlyoffice/data,onlyoffice/lib,drupal/files,drupal/private,traefik/acme,backups,logs,integrations/traefik}
chmod 0750 "$INSTALL_PATH"
chmod 0700 "$INSTALL_PATH/secrets" "$INSTALL_PATH/backups"
for name in postgres postgres/data keycloak keycloak/providers keycloak/themes wehrportal \
  wehrportal/storage wehrportal/storage/app matrix matrix/data fluffychat onlyoffice onlyoffice/logs onlyoffice/data \
  onlyoffice/lib drupal drupal/files drupal/private traefik traefik/acme logs integrations integrations/traefik; do
  [[ ! -L "$INSTALL_PATH/$name" ]] || fail "Refusing symlinked installation directory: $INSTALL_PATH/$name"
  chmod 0750 "$INSTALL_PATH/$name"
done
install -d -m 0750 "$INSTALL_PATH/scripts"
for file in compose.yml scripts/postgres-init.sh scripts/keycloak-entrypoint.sh scripts/wehrportal-entrypoint.sh \
  scripts/onlyoffice-entrypoint.sh scripts/generate-proxy-config.sh scripts/configure-synapse.py \
  scripts/backup.sh scripts/restore.sh scripts/update.sh scripts/migrate-postgres.sh scripts/healthcheck.sh scripts/validate.sh \
  scripts/uninstall.sh scripts/lib.sh scripts/generate-swarm-stack.py scripts/setup-drupal.sh scripts/configure-keycloak.py \
  scripts/setup-apps.sh scripts/setup-wehrportal.sh scripts/configure-wehrportal-oidc.php \
  scripts/synapse-entrypoint.sh scripts/setup-synapse.sh \
  scripts/setup-wehrportal-office.sh scripts/configure-wehrportal-office.php \
  scripts/installation-summary.sh \
  drupal/Dockerfile drupal/.dockerignore drupal/composer.json drupal/composer.lock drupal/settings.php drupal/configure.php drupal/entrypoint.sh; do
  # Stack-managed files are refreshed on every run so updates reach existing installations
  if [[ -e "$INSTALL_PATH/$file" && "$file" == compose.yml ]] && ! cmp -s "$SCRIPT_DIR/$file" "$INSTALL_PATH/$file"; then
    cp -p "$INSTALL_PATH/$file" "$INSTALL_PATH/$file.bak"
  fi
  install -m 0644 "$SCRIPT_DIR/$file" "$INSTALL_PATH/$file"
done
chmod 0755 "$INSTALL_PATH"/scripts/*.sh
for name in postgres_superuser_password keycloak_db_password wehrportal_db_password synapse_db_password \
  keycloak_admin_password onlyoffice_jwt_secret drupal_db_password drupal_hash_salt drupal_admin_password drupal_oidc_client_secret \
  wehrportal_oidc_client_secret synapse_oidc_client_secret; do
  [[ ! -L "$INSTALL_PATH/secrets/$name" ]] || fail "Refusing symlinked secret file: $name"
  if [[ -e "$INSTALL_PATH/secrets/$name" ]]; then
    [[ -f "$INSTALL_PATH/secrets/$name" && -s "$INSTALL_PATH/secrets/$name" ]] || fail "Secret is empty or not a regular file: $name"
  else
    openssl rand -hex 32 > "$INSTALL_PATH/secrets/$name"
  fi
  chmod 0644 "$INSTALL_PATH/secrets/$name"
done
[[ ! -L "$INSTALL_PATH/secrets/wehrportal_app_key" ]] || fail "Refusing symlinked WehrPortal app key"
if [[ ! -e "$INSTALL_PATH/secrets/wehrportal_app_key" && -e "$INSTALL_PATH/secrets/openwehr_app_key" ]]; then
  fail "A legacy APP_KEY exists at secrets/openwehr_app_key; refusing to generate a replacement. Resolve it explicitly before installing."
fi
if [[ ! -e "$INSTALL_PATH/secrets/wehrportal_app_key" ]]; then
  printf 'base64:%s\n' "$(openssl rand -base64 32 | tr -d '\n')" > "$INSTALL_PATH/secrets/wehrportal_app_key"
fi
[[ -s "$INSTALL_PATH/secrets/wehrportal_app_key" ]] ||
  fail "WehrPortal APP_KEY is empty; refusing to generate a replacement."
[[ ! -L "$INSTALL_PATH/secrets/mail_smtp_password" ]] || fail "Refusing symlinked SMTP secret"
if [[ ! -e "$INSTALL_PATH/secrets/mail_smtp_password" ]]; then
  : > "$INSTALL_PATH/secrets/mail_smtp_password"
fi
if [[ -n "$smtp_password" ]]; then
  (umask 077; printf '%s' "$smtp_password" > "$INSTALL_PATH/secrets/mail_smtp_password")
fi
if [[ -n "${values[MAIL_USERNAME]}" && ! -s "$INSTALL_PATH/secrets/mail_smtp_password" ]]; then
  printf 'WARN: secrets/mail_smtp_password ist leer, obwohl ein SMTP-Benutzer gesetzt ist\n' >&2
fi
for name in wehrportal_app_key mail_smtp_password; do
  [[ -f "$INSTALL_PATH/secrets/$name" ]] || fail "Secret path is not a regular file: $name"
  chmod 0644 "$INSTALL_PATH/secrets/$name"
done
for entry in "postgres/data:70:70" "matrix/data:991:991" "keycloak/providers:1000:1000" \
  "keycloak/themes:1000:1000" "wehrportal/storage/app:82:82" "drupal/files:33:33" "drupal/private:33:33"; do
  dir=${entry%%:*}
  owner=${entry#*:}
  uid=${owner%%:*}
  gid=${owner##*:}
  if [[ -z "$(find "$INSTALL_PATH/$dir" -mindepth 1 -print -quit)" ]]; then
    chown "$uid:$gid" "$INSTALL_PATH/$dir"
  fi
done
[[ ! -L "$INSTALL_PATH/traefik/acme/acme.json" ]] || fail "Refusing symlinked Traefik ACME file"
touch "$INSTALL_PATH/traefik/acme/acme.json"
chmod 0600 "$INSTALL_PATH/traefik/acme/acme.json"
if [[ -n "$DNS_ENV_FILE" && ! -e "$INSTALL_PATH/secrets/dns.env" ]]; then
  install -m 0600 "$DNS_ENV_FILE" "$INSTALL_PATH/secrets/dns.env"
fi
[[ ! -L "$INSTALL_PATH/secrets/dns.env" ]] || fail "Refusing symlinked DNS provider file"
# Container users (postgres, keycloak, www-data) read secrets via bind mounts; the 0700 secrets directory keeps them private on the host.
find "$INSTALL_PATH/secrets" -maxdepth 1 -type f ! -name dns.env -exec chmod 0644 {} +
[[ ! -e "$INSTALL_PATH/secrets/dns.env" ]] || chmod 0600 "$INSTALL_PATH/secrets/dns.env"
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
    for key in KEYCLOAK_HOST KEYCLOAK_REALM WEHRPORTAL_HOST MATRIX_HOST FLUFFYCHAT_HOST ONLYOFFICE_HOST DRUPAL_HOST DRUPAL_ADMIN_EMAIL DRUPAL_OIDC_ENABLED WEHRPORTAL_OIDC_ENABLED WEHRPORTAL_OIDC_FORCE_DISABLED MATRIX_OIDC_ENABLED KEYCLOAK_ADMIN_USER WEHRPORTAL_ADMIN_EMAILS; do
      printf '%s=%s\n' "$key" "${values[$key]}"
    done
    printf 'WEHRPORTAL_IMAGE_TAG=%s\nPOSTGRES_IMAGE=%s\n' \
      "${values[WEHRPORTAL_IMAGE_TAG]}" "${values[POSTGRES_IMAGE]}"
    printf 'VPN_BACKEND_IP=%s\nDEPLOY_MODE=%s\n' "${values[VPN_BACKEND_IP]}" "${values[DEPLOY_MODE]}"
    printf 'STACK_MAX_MEMORY_MB=%s\nSTACK_MAX_CPUS=%s\n' "${values[STACK_MAX_MEMORY_MB]}" "${values[STACK_MAX_CPUS]}"
    for name in "${!limit_mem[@]}"; do
      printf 'MEM_%s=%s\nCPU_%s=%s\n' "${name^^}" "${limit_mem[$name]}" "${name^^}" "${limit_cpu[$name]}"
    done | sort
    printf 'TRAEFIK_MIDDLEWARES=%s\n' "${values[TRAEFIK_MIDDLEWARES]}"
    printf 'MAIL_MAILER=smtp\nMAIL_HOST=%s\nMAIL_PORT=%s\nMAIL_USERNAME=%s\nMAIL_ENCRYPTION=%s\n' \
      "${values[MAIL_HOST]}" "${values[MAIL_PORT]}" "${values[MAIL_USERNAME]}" "${values[MAIL_ENCRYPTION]}"
    printf 'MAIL_FROM_ADDRESS=%s\nMAIL_FROM_NAME=%s\n' "${values[MAIL_FROM_ADDRESS]}" "${values[MAIL_FROM_NAME]}"
    for key in KEYCLOAK_PORT WEHRPORTAL_PORT MATRIX_PORT FLUFFYCHAT_PORT ONLYOFFICE_PORT DRUPAL_PORT; do
      printf '%s=%s\n' "$key" "${values[$key]}"
    done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$INSTALL_PATH/.env"
}
write_env
installation_stage="Proxy- und Anwendungskonfiguration pruefen"
info "[2/4] Proxy- und Anwendungskonfiguration erstellen und pruefen ..."

[[ ! -L "$INSTALL_PATH/fluffychat/config.json" ]] || fail "Refusing symlinked FluffyChat config"
if [[ ! -e "$INSTALL_PATH/fluffychat/config.json" ]]; then
  cat > "$INSTALL_PATH/fluffychat/config.json" <<EOF
{
  "applicationName": "Feuerwehr Chat",
  "defaultHomeserver": "${values[MATRIX_HOST]}"
}
EOF
  chmod 0644 "$INSTALL_PATH/fluffychat/config.json"
fi
[[ -f "$INSTALL_PATH/fluffychat/config.json" ]] || fail "FluffyChat config is not a regular file"

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
  installation_stage="Images vorbereiten und Dienste starten"
  info "[3/4] Images vorbereiten und Dienste starten (Downloads und Builds koennen mehrere Minuten dauern) ..."
  if [[ -n "${enabled[drupal]:-}" ]]; then
    "${compose[@]}" build drupal
  fi
  setup_by_update=false
  if [[ -f "$INSTALL_PATH/postgres/data/PG_VERSION" ]]; then
    info "Bestehende PostgreSQL-Daten erkannt: Aktualisierung mit vorgeschaltetem Backup."
    bash "$INSTALL_PATH/scripts/update.sh" --yes --local-files
    setup_by_update=true
  elif [[ "${values[DEPLOY_MODE]}" == swarm ]]; then
    ROOT=$INSTALL_PATH
    # shellcheck source=scripts/lib.sh
    . "$INSTALL_PATH/scripts/lib.sh"
    deploy_stack
  else
    "${compose[@]}" up -d
  fi
  # Existing-cluster updates already perform application setup.
  if [[ "$setup_by_update" != true ]]; then
    installation_stage="Anwendungen und automatische Integrationen einrichten"
    info "[4/4] Anwendungen einrichten; auf Datenbanken, SSO und Online-Office warten ..."
    "$INSTALL_PATH/scripts/setup-apps.sh"
  fi
else
  info "[3/4 und 4/4] Wegen --no-start uebersprungen: keine Dienste gestartet, keine App-Einrichtung ausgefuehrt."
fi
installation_stage="Abschlussuebersicht schreiben"
# shellcheck source=scripts/installation-summary.sh
source "$INSTALL_PATH/scripts/installation-summary.sh"
[[ ! -L "$INSTALL_PATH/installation-info.txt" ]] || fail "Refusing symlinked installation summary"
summary_tmp=$(mktemp "$INSTALL_PATH/.installation-info.XXXXXX")
installation_summary > "$summary_tmp"
chmod 0600 "$summary_tmp"
mv -f "$summary_tmp" "$INSTALL_PATH/installation-info.txt"
cat "$INSTALL_PATH/installation-info.txt"
