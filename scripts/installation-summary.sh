# shellcheck shell=bash
# Sourced by the installer after a successful run; never reads secret contents.
installation_summary() {
  printf '\n=== Ihre Installation im Ueberblick ===\n'
  printf 'Stand: %s\nInstallationspfad: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$INSTALL_PATH"
  if [[ "$NO_START" == true ]]; then
    printf 'Status: Dateien vorbereitet; Anwendungen NOCH NICHT gestartet oder eingerichtet.\n'
    printf 'Die folgenden Adressen und Zugangshinweise gelten erst nach Start und Einrichtung.\n'
  else
    printf 'Status: Dienste gestartet und ausgewaehlte Integrationen eingerichtet.\n'
    printf 'Browser-Erreichbarkeit, TLS und E-Mailversand bitte noch pruefen.\n'
  fi
  printf 'Bereitstellung: %s | Reverse Proxy: %s\n' "${values[DEPLOY_MODE]}" "${values[PROXY_MODE]}"
  printf '\nGemeinsame Dienste: PostgreSQL (getrennte App-Datenbanken) und Redis.\n'
  printf 'Diese Dienste haben keine Browser-Anmeldung und sind nicht oeffentlich freigegeben.\n'
  if [[ "${values[PROXY_MODE]}" == own ]]; then
    printf 'Traefik: eigener Reverse Proxy mit TLS; kein oeffentliches Admin-Dashboard.\n'
  fi

  if [[ -n "${enabled[keycloak]:-}" ]]; then
    printf '\nKeycloak - zentrale Benutzerverwaltung\n'
    printf '  Verwaltung: https://%s/admin/\n' "${values[KEYCLOAK_HOST]}"
    printf '  Benutzerkonto: https://%s/realms/%s/account/\n' "${values[KEYCLOAK_HOST]}" "${values[KEYCLOAK_REALM]}"
    printf '  Realm: %s | Initialer Administrator: %s\n' "${values[KEYCLOAK_REALM]}" "${values[KEYCLOAK_ADMIN_USER]}"
    printf '  Initiales Passwort: %s/secrets/keycloak_admin_password\n' "$INSTALL_PATH"
    printf '  Anwendungskonten im Realm anlegen; der Bootstrap-Admin ist kein App-Admin.\n'
  fi
  if [[ -n "${enabled[wehrportal]:-}" ]]; then
    printf '\nWehrPortal\n  Browser: https://%s/anmelden\n' "${values[WEHRPORTAL_HOST]}"
    printf '  Initiale Administrator-E-Mail(s): %s\n' "${values[WEHRPORTAL_ADMIN_EMAILS]}"
    printf '  Lokaler Adminzugang: https://%s/anmelden/lokal\n' "${values[WEHRPORTAL_HOST]}"
    printf '  Kein lokales Passwort: Anmeldung per E-Mail-Link; funktionierendes SMTP ist erforderlich.\n'
    if [[ "${values[WEHRPORTAL_OIDC_ENABLED]}" == true ]]; then
      if [[ "${values[WEHRPORTAL_OIDC_FORCE_DISABLED]}" == true ]]; then
        printf '  Keycloak-SSO bleibt durch WEHRPORTAL_OIDC_FORCE_DISABLED deaktiviert.\n'
      else
        printf '  Keycloak-SSO eingerichtet; initial nur fuer vorhandene aktive Konten mit bestaetigter E-Mail.\n'
      fi
    fi
    printf '  SMTP-Passwortdatei: %s/secrets/mail_smtp_password (vom Mailanbieter, kein Portalpasswort).\n' "$INSTALL_PATH"
    if [[ -n "${values[MAIL_USERNAME]}" && ! -s "$INSTALL_PATH/secrets/mail_smtp_password" ]]; then
      printf '  ACHTUNG: SMTP-Passwortdatei ist leer, obwohl ein SMTP-Benutzer gesetzt ist.\n'
    fi
  fi
  if [[ -n "${enabled[matrix]:-}" ]]; then
    printf '\nMatrix Synapse und FluffyChat\n'
    printf '  Chat im Browser: https://%s/\n  Homeserver/API: https://%s/\n' \
      "${values[FLUFFYCHAT_HOST]}" "${values[MATRIX_HOST]}"
    printf '  Matrix-Kennung: @benutzer:%s\n' "${values[MATRIX_SERVER_NAME]}"
    if [[ "${values[MATRIX_OIDC_ENABLED]}" == true ]]; then
      printf '  Im Chat Keycloak/SSO waehlen; beim ersten Login entsteht ein normales Matrix-Konto.\n'
    else
      printf '  Kein SSO eingerichtet; lokale Matrix-Konten muessen separat angelegt werden.\n'
    fi
    printf '  Kein initialer Matrix-Admin und kein Matrix-Passwort erzeugt; offene Registrierung ist aus.\n'
    if [[ "${values[MATRIX_SERVER_NAME]}" != "${values[MATRIX_HOST]}" ]]; then
      printf '  Identitaetsdomain weicht vom API-Host ab: Matrix-/.well-known-Dateien separat einrichten.\n'
    fi
  fi
  if [[ -n "${enabled[onlyoffice]:-}" ]]; then
    printf '\nONLYOFFICE Docs\n  Serveradresse: https://%s/\n' "${values[ONLYOFFICE_HOST]}"
    printf '  Dokumenteditor, kein eigenes Benutzerportal; kein initialer Benutzer und kein Loginpasswort.\n'
    if [[ -n "${enabled[wehrportal]:-}" ]]; then
      printf '  Online-Office in WehrPortal konfiguriert. Dateien-Modul und Nutzerrechte im Portal freigeben.\n'
    else
      printf '  Ohne WehrPortal: Document Server fuer eine separat anzubindende Anwendung.\n'
    fi
    printf '  Gemeinsames JWT-Secret: %s/secrets/onlyoffice_jwt_secret (kein Benutzerpasswort).\n' "$INSTALL_PATH"
  fi
  if [[ -n "${enabled[drupal]:-}" ]]; then
    printf '\nDrupal Website\n  Website: https://%s/\n  Anmeldung: https://%s/user/login\n' \
      "${values[DRUPAL_HOST]}" "${values[DRUPAL_HOST]}"
    printf '  Lokaler Administrator: siteadmin | E-Mail: %s\n' "${values[DRUPAL_ADMIN_EMAIL]}"
    printf '  Initiales Passwort: %s/secrets/drupal_admin_password\n' "$INSTALL_PATH"
    if [[ "${values[DRUPAL_OIDC_ENABLED]}" == true ]]; then
      printf '  Keycloak-Login ueber OpenID Connect; neue SSO-Konten erhalten keine Adminrechte.\n'
    fi
  fi
  printf '\nWichtige Hinweise\n'
  if [[ "${values[PROXY_MODE]}" == remote && "${values[ENABLE_PROXY_ROUTES]}" == true ]]; then
    printf '  Remote-Proxy: %s/integrations/traefik/dynamic.yml auf den Proxy uebertragen.\n' "$INSTALL_PATH"
    printf '  VPN-Routen, DNS und TLS am entfernten Proxy muessen eingerichtet sein.\n'
  fi
  if [[ "${values[ENABLE_PROXY_ROUTES]}" != true ]]; then
    printf '  Proxy-Routen sind deaktiviert: Browseradressen erst nach manueller Routeneinrichtung erreichbar.\n'
  fi
  printf '  DNS muss auf den Reverse Proxy zeigen; HTTPS-Zertifikate muessen gueltig sein.\n'
  printf '  Passwortdateien enthalten Anfangswerte; spaetere Passwortaenderungen werden nicht zurueckgeschrieben.\n'
  printf '  Kennwoerter werden nicht ausgegeben. Secret-Dateien nur lokal mit root-Rechten lesen, nicht weitergeben.\n'
  printf '  .env, secrets/ und Backups schuetzen und verschluesselt extern sichern.\n'
  printf '\nNaechste Schritte (im Installationsverzeichnis)\n'
  printf '  cd %q\n' "$INSTALL_PATH"
  if [[ "$NO_START" == true ]]; then
    printf '  sudo ./scripts/update.sh --local-files  # Anwendungen starten und Integrationen einrichten\n'
  fi
  printf '  sudo ./scripts/healthcheck.sh           # Dienstestatus pruefen\n'
  printf '  sudo ./scripts/setup-apps.sh            # Einrichtung nach Fehlerkorrektur wiederholen\n'
  printf '  sudo ./scripts/backup.sh                # Erstes Backup nach erfolgreicher Einrichtung\n'
  printf '\nDiese Uebersicht: %s/installation-info.txt (enthaelt keine Kennwoerter).\n' "$INSTALL_PATH"
}
