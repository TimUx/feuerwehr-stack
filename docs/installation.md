# Installation und Erstkonfiguration

## Betriebssystem und Host

Der Installer akzeptiert Debian und Ubuntu sowie Docker Engine, Compose-Plugin v2, OpenSSL, `ss`, `df` und Root. Für WehrPortal sind zusätzlich `curl` und Python 3 zur Release-Prüfung erforderlich. Der Online-Einzeiler benötigt `curl` und `tar`. Er installiert keine Pakete und aktualisiert keine Systemdienste. Docker muss erreichbar sein. Bei `own` müssen TCP 80 und 443 frei sein; bei `same-host` muss das konfigurierte externe Netz bereits bestehen.

## Einstellungen

Kopiere `config/installation.env.example` und setze mindestens echte Domainnamen, ACME-E-Mail, SMTP-Server/-Absender sowie die gewünschten `ENABLED_APPS`. `BASE_DOMAIN` ist die Primärdomain inklusive Endung; `*_HOST` enthält jeweils den vollständigen DNS-Namen. Interaktiv fragt der Installer für jede Anwendung nach der Auswahl sowie nach dem Subdomain-Label unter der Primärdomain. Die Standards sind `login` (Keycloak), `portal` (WehrPortal), `matrix` (Synapse), `messenger` (FluffyChat), `docs` (ONLYOFFICE) und `www` (Website). Werte werden zeilenweise als `KEY=VALUE` gelesen, nicht als Shell-Code ausgeführt. Unbekannte Schlüssel werden ignoriert. Bestehende `.env`-Werte sind bei erneuten Installationen die Quelle der Wahrheit.
Zusätzlich werden `STACK_MAX_MEMORY_MB` (mindestens 4096) und `STACK_MAX_CPUS` (mindestens 1) abgefragt. Der Installer verteilt dieses Gesamtbudget auf die aktivierten Dienste und schreibt die abgeleiteten `MEM_*`- und `CPU_*`-Werte in `.env`.

Secrets werden separat erstellt. Gib keine Passwörter in die Konfigurationsdatei ein. Für DNS-01 wird eine zusätzliche Provider-Env-Datei benötigt; sie wird als `secrets/dns.env` geschützt abgelegt.

## Installer und Dry-Run

```bash
sudo ./install.sh --help
sudo ./install.sh --config ./config/installation.env --dry-run
sudo ./install.sh --config ./config/installation.env --path /srv/apps/feuerwehr
```

`--dry-run` führt keine Dateierstellung, Image-Pulls oder Containerstarts aus. Er prüft Domainsyntax, Reverse-Proxy-Auswahl, Remote-IP/Ports und bei eigenem Traefik belegte Ports. Docker-Netzwerk- und Hostchecks werden bei einer regulären Installation durchgeführt. `--no-start` bereitet die Stackdateien vor und lässt die eigentliche Diensteausführung aus.
Bei erneuten Installationen aktualisiert der Installer `compose.yml` und `scripts/*` aus dem aktuellen Repository-Stand; bei Änderungen wird `compose.yml` vorab als `compose.yml.bak` gesichert.

Vor der ersten Änderung zeigt der Installer Pfad, aktive Dienste, die DNS-Namen der ausgewählten Apps, Proxy-Modus und Matrix-Federation und verlangt Bestätigung. Lege die angezeigten DNS-Einträge vorher beim DNS-Anbieter an; der Installer konfiguriert keine DNS-Zone. `--yes` überspringt nur diese Bestätigung; es deaktiviert keine Validierungen.

## Erststart

Bei aktivem Matrix-Profil erzeugt der Synapse-Container beim ersten Start seine Konfiguration und setzt PostgreSQL sowie die verwalteten SSO-Werte. Das gilt auch beim späteren manuellen Start nach `--no-start`; anschließend `sudo ./scripts/setup-apps.sh` für die ausgewählten OIDC-Anwendungen aufrufen.

Bei ausgewähltem WehrPortal prüft der Installer standardmäßig `ghcr.io/timux/wehrportal:latest` vor Änderungen am Installationspfad und speichert `WEHRPORTAL_IMAGE_TAG=latest` in `.env`. Bei bestehenden Installationen den alten festen Wert in `.env` einmalig auf `latest` ändern oder den Installer mit der aktualisierten Konfiguration erneut ausführen. Ein expliziter Release-Tag bleibt möglich und wird über GitHub und GHCR verifiziert. PostgreSQL ist Pflicht. Der WehrPortal-Produktionscontainer führt Datenbankmigrationen und Scheduler beim Start selbst aus; der separate Worker startet ohne parallele Migrationen. Die initialen Admin-Adressen werden über `WEHRPORTAL_ADMIN_EMAILS` konfiguriert.

`scripts/update.sh` migriert PostgreSQL bei einem Major-Versionswechsel automatisch per logischem Dump/Restore. Vor der Migration entsteht zusätzlich zum regulären Backup ein vollständiger Cluster-Dump; die bisherige Datendatei bleibt nach erfolgreichem Wechsel unter `postgres/data.pg<Major>-<Zeitstempel>` erhalten. Plane Downtime und mindestens zusätzlichen Speicherplatz für ein weiteres vollständiges Cluster und das komprimierte Backup ein. Downgrades werden nicht automatisch unterstützt.

WehrPortal unterstützt keine Übernahme bestehender OpenWehr-Daten. Der Installer lehnt einen alten Stack-Pfad oder ein bestehendes PostgreSQL-Datenverzeichnis ab. Installiere WehrPortal in einem separaten leeren Pfad und bewahre alte Installation, Backups und Secrets unverändert auf.

Keycloak-Bootstrap-Zugangsdaten findest du nach Installation geschützt in `secrets/`. Das Passwort wird nicht angezeigt. Der Installer fragt `KEYCLOAK_REALM` ab. Sind Drupal, WehrPortal und/oder Matrix zusammen mit Keycloak gewählt, werden Realm, getrennte App-Clients und die jeweilige OIDC-Konfiguration automatisch eingerichtet. Dafür ist Python 3 auf dem Host erforderlich.

### Matrix und FluffyChat

Bei gemeinsamer Auswahl von Matrix und Keycloak setzt der Installer `MATRIX_OIDC_ENABLED=true`, erzeugt `secrets/synapse_oidc_client_secret` und richtet den confidential Client `synapse` im angegebenen Realm ein. Ausschließlicher Callback: `https://<MATRIX_HOST>/_synapse/client/oidc/callback`; Authorization Code und PKCE S256 sind verpflichtend. Die `public_baseurl` entspricht `MATRIX_HOST`, nicht einer gegebenenfalls abweichenden Matrix-Identitätsdomain `MATRIX_SERVER_NAME`.

Öffne FluffyChat unter `https://<FLUFFYCHAT_HOST>/`, verwende den vorkonfigurierten Homeserver und dessen SSO-/Keycloak-Anmeldung. Keycloak übernimmt den Login; Synapse erstellt beim ersten Login ein normales Konto ohne Adminrechte und gibt einen einmalig einlösbaren Login-Token an den Client zurück. Die Anmeldung benötigt keinen eigenen FluffyChat-OIDC-Client. Der Stack vertraut ausschließlich der exakten HTTPS-Origin des eigenen Webclients für die Token-Rückgabe ohne zusätzliche Bestätigung; andere Clients erhalten Synapses Rückfrage.

Neue SSO-Konten sind erlaubt, offene Matrix-Registrierung bleibt gesperrt. Bestehende Konten werden nicht automatisch mit Keycloak verknüpft; bei belegten Namen erzeugt Synapse einen anderen Matrix-Namen, etwa mit Ziffernsuffix. Lokaler Passwortlogin bleibt möglich, ein Notfalladmin wird nicht automatisch angelegt. Datenbank, Signaturschlüssel und Secrets dauerhaft sichern. Ohne Keycloak wird kein verwalteter OIDC-Provider aktiviert.

Keycloak muss aus Synapse und vom Host über gültiges HTTPS erreichbar sein. Bei der Erstinstallation kann Synapse bis zur Realm-Provisionierung neu starten; das gemeinsame Setup wartet auf den angebotenen Keycloak-Loginflow. Nach Fehlerkorrektur Synapse neu starten und `sudo ./scripts/setup-apps.sh` wiederholen. Änderungen an Realm/Domain zuerst in Keycloak abgleichen, dann Synapse neu erstellen/deployen und die Bereitschaft erneut prüfen; der Startwrapper setzt die verwalteten Werte bei jedem Start erneut.

## WehrPortal mit Keycloak

Bei gemeinsamer Auswahl wird `WEHRPORTAL_OIDC_ENABLED=true` automatisch gesetzt. Python 3 auf dem Host und ein Image mit der vorhandenen `extensions/Oidc`-Erweiterung sind erforderlich. Webcontainer und Worker erhalten konsistent `OIDC_ENABLED`; die Konfiguration erfolgt nach den automatischen Migrationen über WehrPortals `OidcSettings`-API. Der Client `wehrportal` hat ein eigenes Secret und ausschließlich den Callback `https://<WEHRPORTAL_HOST>/auth/oidc/callback`. Anmeldung erfolgt unter `/anmelden`.

Keycloak muss aus dem Portal über **öffentlich auflösbares HTTPS auf Port 443** erreichbar sein. Private Docker-/VPN-/Loopback-Adressen, auch durch Split-DNS, werden vom Portal abgewiesen. Den SSRF-Schutz nicht für das Setup abschalten. Bei Bedarf muss die öffentliche Route auch vom Backend aus erreichbar sein (Hairpin-Routing).

Default: Magic-Link und SSO parallel, keine automatische Kontoanlage, Verknüpfung nur vorhandener aktiver Konten über bestätigte E-Mail. Keine Rollenübernahme aus Claims. Fachliche Zugänge vergibt ein Portaladministrator. Nachträgliche Konten-/Adminrichtlinien im Portal werden nicht vom Setup überschrieben. Verbindungseinstellungen und Aktivierung bleiben Stack-verwaltet.

`WEHRPORTAL_OIDC_FORCE_DISABLED=true` schaltet den IdP-Login unabhängig von gespeicherten Settings aus. Nach Änderung Webcontainer und Worker neu erstellen/deployen; ein bloßes `docker compose restart` übernimmt keine geänderten Umgebungswerte. Lokale Admins nutzen `/anmelden/lokal` und benötigen funktionierendes SMTP. Erneute Installation übernimmt den Schalter, erneutes Setup hebt ihn nicht auf.

## WehrPortal und ONLYOFFICE

Bei gemeinsamer Auswahl in `ENABLED_APPS` konfiguriert der Installer nach den Migrationen automatisch die Online-Office-Einstellungen des vorhandenen Dateien-Moduls. Keycloak wird dafür nicht benötigt. Browser-URL: `https://<ONLYOFFICE_HOST>`, interne Server-URL: `http://onlyoffice`, Download-/Rückrufbasis: `https://<WEHRPORTAL_HOST>`. Das bereits erzeugte `secrets/onlyoffice_jwt_secret` wird dem Portal-Webcontainer zusätzlich schreibgeschützt bereitgestellt und über `OfficeSettings::save` mit `APP_KEY` verschlüsselt gespeichert; der Worker erhält keinen Klartext-Mount.

Das Dateien-Modul muss in WehrPortal aktiviert und den gewünschten Nutzern zugewiesen sein; der Installer ändert weder Modul-/Dateirechte noch vorhandene Bearbeitungs- und Formatbeschränkungen. Technische Office-URLs und Secret werden bei Installation, Update, Restore sowie `sudo ./scripts/setup-apps.sh` abgeglichen. Der Ablauf wartet bis zu etwa zehn Minuten auf ONLYOFFICE und Portal-Migrationen und meldet fehlende Bereitschaft als Fehler. Bei `--no-start` erfolgt der Abgleich erst nach dem manuellen Start und Aufruf des Setups.

Die öffentliche Portal-Adresse muss aus ONLYOFFICE mit gültigem HTTPS erreichbar sein, die öffentliche Office-Adresse aus dem Browser. Das interne Docker-Netz übernimmt Portal→ONLYOFFICE. Keine zusätzliche Proxy-Anmeldung vor Download-/Callback-Routen setzen; diese authentifizieren über Sitzungstoken und JWT. Eine private DNS-Auflösung der Portal-Domain kann vom Document Server blockiert werden; der Stack deaktiviert diesen Schutz nicht pauschal.

## Drupal

Drupal wird mit `drupal` in `ENABLED_APPS` ausgewählt. `DRUPAL_HOST` ist standardmäßig `www.<BASE_DOMAIN>`; `DRUPAL_ADMIN_EMAIL` gehört zum lokalen Notfalladministrator `siteadmin`. Die Site wird beim ersten Start automatisch installiert.

Für Drupal sind Python 3 auf dem Host, Internetzugang zum lokalen Image-Build sowie PostgreSQL 16 oder neuer erforderlich. Die gepinnte Version ist Drupal 11.4.11; der Build enthält Drush und OpenID Connect 1.6.0 mit Composer-Lockfile. Der Installer erzeugt DB-Passwort, Hash-Salt, Notfalladmin-Passwort und OIDC-Client-Secret einmalig als geschützte Dateien unter `secrets/`.

`DRUPAL_OIDC_ENABLED` wird aus der App-Auswahl abgeleitet: nur bei Drupal + Keycloak `true`. Der Client `drupal` erlaubt ausschließlich den Callback `https://<DRUPAL_HOST>/openid-connect/generic`. Anmeldung erfolgt unter `/user/login`. Neue SSO-Konten erhalten keine Redaktions-/Administratorrechte; diese vergibt ein berechtigter Drupal-Administrator separat. Ein Keycloak-Nutzer braucht eine E-Mail-Adresse. Das Bootstrap-Administratorkonto von Keycloak erhält keine Drupal-Rechte.

Der Stack verwaltet den generischen OIDC-Provider und die Login-/Registrierungseinstellungen; sie werden bei jedem Drupal-Start erneut gesetzt. Änderungen daran gehören in die verwalteten Builddateien, nicht ausschließlich in die Drupal-Administrationsoberfläche. Eine unbekannte, nicht leere Datenbank wird nicht automatisch neu installiert oder geleert.

Nach `--no-start` die vorbereiteten Dateien mit `sudo ./scripts/update.sh --local-files` bauen/starten und provisionieren. `scripts/setup-apps.sh` lässt sich nach einem fehlgeschlagenen Bootstrap erneut ausführen. Es koordiniert einmalig den Keycloak-Abgleich für alle ausgewählten SSO-Anwendungen und ruft die jeweiligen App-Setups auf. Das Drupal-Setup ergänzt auch in vorhandenen PostgreSQL-Clustern die Drupal-Datenbank, Rolle und `pg_trgm`, ohne vorhandene Passwörter zu ersetzen.

Für den OIDC-Bootstrap müssen die Keycloak-Domain und ihr TLS-Zertifikat vom Stack-Host erreichbar sein; Drupal muss Keycloak ebenfalls über HTTPS erreichen. Im `remote`-Modus die erzeugte Traefik-Konfiguration vorher auf den Proxy übertragen. Fehlende Erreichbarkeit wird nicht stillschweigend übergangen. Wiederholte Provisionierung braucht gültige Keycloak-Adminzugangsdaten aus den Bootstrap-Dateien. Fremde gleichnamige Clients werden nicht überschrieben; nur als Stack-verwaltet markierte Clients werden abgeglichen.

## Manuelle Compose-Kommandos

Für den Betrieb sind die Skripte vorzuziehen. Bei direkten Compose-Aufrufen müssen die generierten Override-Dateien angegeben werden:

```bash
cd /srv/apps/feuerwehr
files=(-f compose.yml)
[[ ! -f compose.proxy.yml ]] || files+=(-f compose.proxy.yml)
[[ ! -f compose.remote.yml ]] || files+=(-f compose.remote.yml)
sudo docker compose --project-directory "$PWD" "${files[@]}" up -d
```
