# Feuerwehr-Stack

Modularer Docker-Compose-Stack für eine einzelne Debian-/Ubuntu-Maschine. Der Installer legt Konfiguration, Secrets und persistente Anwendungsdaten unter einem frei wählbaren Pfad ab (Standard: `/srv/apps/feuerwehr`). Docker Swarm wird nicht benötigt.

## Status und Grenzen

| Bestandteil | Status |
| --- | --- |
| Installer, Profile, sichere lokale Secrets und Compose-Konfiguration | Implementiert; Syntax- und Compose-Modelltests vorhanden |
| Eigener Traefik, vorhandener Traefik auf demselben Docker-Host, entfernter Traefik über VPN | Konfiguration wird je Modus erzeugt; produktive DNS-/TLS-/VPN-Verbindungen hier nicht getestet |
| PostgreSQL mit getrennten Datenbanken/Rollen | Implementiert; `scripts/update.sh` erstellt vor Major-Upgrades einen vollständigen Dump und migriert das Cluster logisch |
| Keycloak | Realm und getrennte OIDC-Clients für Drupal, WehrPortal und Synapse werden automatisch eingerichtet |
| WehrPortal | Produktions-Image `ghcr.io/timux/wehrportal:latest` (Tag in `.env`), PostgreSQL, Redis, Queue-Worker, SMTP und automatisches Keycloak-OIDC |
| Matrix Synapse und FluffyChat Web | PostgreSQL, automatisches Keycloak-SSO bei gemeinsamer Auswahl; offene Registrierung ist aus |
| ONLYOFFICE Docs | Gemeinsames JWT-Secret und automatische Online-Office-Konfiguration im WehrPortal-Dateien-Modul bei gemeinsamer Auswahl |
| Drupal | Drupal 11.4.11, gemeinsame PostgreSQL-Instanz mit eigener DB/Rolle, automatische Installation und Keycloak-OIDC |

**Noch nicht integriert:** automatische Matrix-`/.well-known`-Dateien. OIDC-Anmeldung ersetzt keine fachliche Rechteverwaltung. Prüfe insbesondere Login, E-Mailversand, Dokumentbearbeitung, Backups, Wiederherstellung und Updatepfade vor produktiver Nutzung.

Die Standardtests starten keine Container. Separate Integrationstests prüfen Drupal, WehrPortal, Matrix-SSO und ONLYOFFICE in isolierten Docker-Netzwerken; sie ersetzen keine Abnahme der produktiven DNS-/Proxy-/TLS-Konfiguration.

## Voraussetzungen

- Unterstütztes Betriebssystem laut Installer: Debian oder Ubuntu; Docker Engine und Docker Compose Plugin v2 müssen bereits installiert und erreichbar sein. Der Installer installiert Docker nicht.
- Root-Rechte (`sudo`) für Installation und Host-Verzeichnisse.
- Für WehrPortal muss das Image `ghcr.io/timux/wehrportal:latest` in GHCR verfügbar sein; explizite Release-Tags werden zusätzlich über GitHub verifiziert.
- Mindestens 5 GiB freier Speicher; bei ausgewähltem ONLYOFFICE mindestens 8 GiB. ONLYOFFICE empfiehlt außerdem mindestens 4 GiB RAM.
- DNS-Einträge für alle aktivierten Anwendungen. Beim eigenen Traefik müssen TCP 80 und 443 öffentlich zum Host führen.
- Für WehrPortal: SMTP-Zugangsdaten und mindestens eine Administrator-E-Mail-Adresse. Standardmäßig wird das veröffentlichte GHCR-Image `latest` geprüft; explizite Release-Tags werden zusätzlich über GitHub verifiziert. Ein nicht veröffentlichtes Image führt zum Abbruch.
- Für Drupal: Python 3 auf dem Host, PostgreSQL ab Version 16 und Internetzugang für den lokalen Image-Build. Der Stack installiert `pg_trgm` in der Drupal-Datenbank. Keycloak muss für den automatischen OIDC-Bootstrap über seine öffentliche HTTPS-Domain erreichbar sein.
- Für WehrPortal mit Keycloak: Python 3 auf dem Host und eine aus dem Portal öffentlich auflösbare Keycloak-HTTPS-Domain auf Port 443. Private DNS-/VPN-/Docker-Zieladressen werden von WehrPortals SSRF-Schutz abgelehnt; Split-DNS auf private Adressen reicht nicht aus.

Lege vorab beispielsweise folgende DNS-Einträge an (nur aktivierte Dienste sind erforderlich; alle zeigen auf den Reverse Proxy):

```text
login.feuerwehr.example.de    -> Reverse Proxy (Keycloak)
portal.feuerwehr.example.de   -> Reverse Proxy (WehrPortal)
matrix.feuerwehr.example.de   -> Reverse Proxy
messenger.feuerwehr.example.de -> Reverse Proxy (FluffyChat Web)
docs.feuerwehr.example.de     -> Reverse Proxy
www.feuerwehr.example.de      -> Reverse Proxy
```

## Installation

### Installation direkt aus der Konsole

Der folgende Einzeiler lädt zuerst das vollständige Stack-Archiv herunter und startet erst nach erfolgreichem Download den interaktiven Installer. Eingaben bleiben interaktiv; bei Download- oder Entpackfehlern wird kein Skript ausgeführt:

```bash
bash -c 'set -Eeuo pipefail; tmp=$(mktemp -d); trap '\''rm -rf -- "$tmp"'\'' EXIT; curl --fail --location --silent --show-error https://codeload.github.com/TimUx/feuerwehr-stack/tar.gz/refs/heads/main --output "$tmp/stack.tar.gz"; tar -xzf "$tmp/stack.tar.gz" -C "$tmp"; sudo "$tmp/feuerwehr-stack-main/install.sh"'
```

1. Repository auf den Zielhost übertragen und `config/installation.env.example` kopieren und anpassen. Konfigurationsdateien enthalten keine Passwörter.
2. Gewünschte Anwendungen im Schlüssel `ENABLED_APPS` angeben: `keycloak`, `wehrportal`, `matrix`, `onlyoffice`, `drupal`. Ohne Konfigurationsdatei fragt der Installer interaktiv für jede Anwendung nach, ob sie installiert werden soll.
3. Konfiguration prüfen:

   ```bash
   sudo ./install.sh --config ./config/installation.env.example --dry-run
   ```

4. Installieren (der Installer zeigt die Einstellungen und fragt vor Änderungen nach):

   ```bash
   sudo ./install.sh --config ./config/installation.env.example
   ```

   Alternativ ohne Konfigurationsdatei interaktiv: `sudo ./install.sh`. Dabei werden Primärdomain (mit Endung), App-Auswahl und je aktivierter Anwendung das DNS-Subdomain-Label abgefragt. Standardwerte sind `login` (Keycloak), `portal` (WehrPortal), `matrix` (Synapse), `messenger` (FluffyChat), `docs` (ONLYOFFICE) und `www` (Website). Für Konfigurationsdateien bleiben die `*_HOST`-Werte vollständige Domainnamen. Der Pfad kann mit `--path /anderer/pfad` überschrieben werden. `--no-start` legt Dateien und Secrets an, startet aber keine Container.

Enter übernimmt den Wert in `[Klammern]`; Ja/Nein-Fragen akzeptieren deutsche und englische Antworten. Bei interaktiven Eingaben werden typische Fehler wie eine URL statt einer Domain, ungültige Auswahlen oder Ports direkt erklärt und erneut abgefragt. Konfigurationsdateien werden dagegen strikt geprüft: Ungültige Werte führen zum Abbruch, nicht zu stillen Ersatzwerten. Nur relevante Fragen werden gestellt – beispielsweise SMTP nur für WehrPortal, Federation nur für Matrix und VPN-Ports nur für ausgewählte Anwendungen im Remote-Modus. Bei der SMTP-Verschlüsselung bedeutet `-` ausdrücklich unverschlüsselt; Enter übernimmt die Vorgabe. SMTP-Passwörter werden unsichtbar eingelesen.

`--yes` überspringt nur die abschließende Bestätigung, nicht Prüfungen oder fehlende Eingaben. Ohne Terminal sollte eine vollständige `--config` verwendet werden. Vor dieser Bestätigung bleibt das Installationsziel unverändert. Danach zeigen vier Schritte den Fortschritt; Downloads, Builds und die erste App-Einrichtung können mehrere Minuten dauern. Bei Fehlern nennt der Installer den betroffenen Schritt und meldet die Einrichtung nicht als erfolgreich.

Der Installer kontrolliert Betriebssystem-ID, Root-Rechte, Docker/Compose-Erreichbarkeit, Speicherplatz und bei eigenem Traefik die Hostports. Bei vorhandenen Traefik-Netzwerken prüft er den exakten Netzwerknamen. DNS-Auflösung wird als Warnung angezeigt, wenn `getent` verfügbar ist. Er verändert keine Docker-Netzwerke und überschreibt keine vorhandenen Secret-Dateien. Ein nicht leeres Ziel ohne Stack-`.env` wird abgelehnt.
Bei erneuten Installationsläufen aktualisiert der Installer die Stack-Dateien `compose.yml`, `scripts/*` und die Drupal-Builddateien automatisch aus dem Repository-Stand. Vor dem Ersetzen von `compose.yml` wird bei Änderungen eine Sicherung als `compose.yml.bak` erzeugt.
Zusätzlich fragt der Installer ein Gesamtbudget für RAM (`STACK_MAX_MEMORY_MB`) und CPU (`STACK_MAX_CPUS`) ab, verteilt es auf die aktiven Dienste und schreibt die resultierenden `MEM_*`-/`CPU_*`-Werte in `.env`.
Findet der Installer bereits PostgreSQL-Daten, führt er den Start über `scripts/update.sh` aus, damit ein Major-Version-Wechsel zuerst gesichert und migriert wird.

WehrPortal wird standardmäßig als `ghcr.io/timux/wehrportal:latest` gestartet; der Installer prüft, ob dieses Image in GHCR verfügbar ist, und schreibt `WEHRPORTAL_IMAGE_TAG=latest` in `.env`. Ein expliziter veröffentlichter Versionstag bleibt möglich und wird über GitHub und GHCR verifiziert.

WehrPortal ist eine Neuinstallation ohne Übernahme von OpenWehr-Bestandsdaten. Ein vorhandenes Stack-Verzeichnis mit OpenWehr-Konfiguration oder PostgreSQL-Daten wird nicht überschrieben oder migriert; für WehrPortal ist ein separater, leerer Installationspfad erforderlich. Die alte Installation und ihre Daten bleiben für einen manuellen Rückweg erhalten.

Auch nach `--no-start` erzeugt Synapse seine Erstkonfiguration beim ersten Containerstart automatisch. Bei ausgewählten SSO-Anwendungen nach dem Start `sudo ./scripts/setup-apps.sh` ausführen; dafür muss Keycloak über HTTPS erreichbar sein.

### Abschlussübersicht und erste Anmeldung

Am Ende zeigt der Installer nur die ausgewählten Anwendungen mit Browseradressen, Anmeldeverfahren, gegebenenfalls Benutzernamen und den Pfaden der passenden Passwortdateien. Dieselbe Übersicht wird mit Zeitstempel unter `<Installationspfad>/installation-info.txt` gespeichert (Modus `0600`, nur mit root-Rechten lesbar). Sie enthält **keine Kennwörter oder Secret-Inhalte**:

```bash
sudo cat /srv/apps/feuerwehr/installation-info.txt
```

- **Keycloak:** Verwaltung unter `https://<KEYCLOAK_HOST>/admin/`, initialer Benutzer aus `KEYCLOAK_ADMIN_USER` (Standard `kcadmin`), Anfangspasswort in `secrets/keycloak_admin_password`. Anwendungskonten im gewählten Realm anlegen; das Bootstrap-Konto ist kein App-Administrator.
- **WehrPortal:** `https://<WEHRPORTAL_HOST>/anmelden`, lokale Administratoren über `/anmelden/lokal` und die konfigurierten E-Mail-Adressen. Es gibt kein erzeugtes Portalpasswort: Der Zugang erfolgt per Mail-Link und gegebenenfalls Keycloak-SSO. `secrets/mail_smtp_password` gehört zum Mailanbieter, nicht zur Portal-Anmeldung.
- **Matrix/FluffyChat:** `https://<FLUFFYCHAT_HOST>/` mit Homeserver `MATRIX_HOST`. Bei gemeinsamer Keycloak-Auswahl SSO verwenden. Es werden weder ein lokaler Matrix-Administrator noch dessen Passwort erzeugt; offene Registrierung bleibt aus.
- **ONLYOFFICE:** `https://<ONLYOFFICE_HOST>/` ist der Document Server, kein eigenes Benutzerportal. Dokumente werden aus dem Dateien-Modul von WehrPortal geöffnet. `secrets/onlyoffice_jwt_secret` verbindet die Dienste und ist kein Loginpasswort.
- **Drupal:** Website unter `https://<DRUPAL_HOST>/`, Anmeldung unter `/user/login`. Lokaler Administrator `siteadmin`, Anfangspasswort in `secrets/drupal_admin_password`; Keycloak-SSO bei gemeinsamer Auswahl.

Passwortdateien bei Bedarf ausschließlich lokal und mit root-Rechten lesen, z.B. `sudo cat /srv/apps/feuerwehr/secrets/keycloak_admin_password`. Anfangspasswörter bleiben in diesen Dateien erhalten, auch wenn sie später in der Anwendung geändert werden; sie sind dann kein Nachweis des aktuellen Passworts. Zugangsdaten nicht in Chats, Screenshots oder Fehlerberichte kopieren.

Bei `--no-start` heißt der Abschluss ausdrücklich **nur vorbereitet**: Die Adressen und Zugangshinweise sind geplant, Konten und Integrationen noch nicht eingerichtet. Start und Einrichtung erfolgen anschließend aus dem Installationsverzeichnis mit `sudo ./scripts/update.sh --local-files`. Bei einem fehlgeschlagenen Lauf wird keine neue Abschlussübersicht geschrieben; eine Datei aus einem früheren Lauf beschreibt nur dessen damaligen Stand.

Die Meldung nach einem normalen Lauf bestätigt Start und Einrichtung, nicht die Erreichbarkeit aus jedem Browser. DNS, gültiges HTTPS, SMTP und gegebenenfalls die Übertragung der Remote-Proxy-Datei bleiben zu prüfen. Deaktivierte Proxy-Routen und der WehrPortal-SSO-Notfallschalter werden in der Übersicht kenntlich gemacht. Mit `sudo ./scripts/healthcheck.sh` den Dienstestatus prüfen und danach ein erstes Backup erstellen.

## Bedienung

Arbeite im Installationspfad. Der Compose-Projektname ist `feuerwehr`. Je nach Proxy-Modus fügt der Installer `compose.proxy.yml` oder `compose.remote.yml` hinzu; die Betriebs-Skripte berücksichtigen erzeugte Dateien automatisch.

```bash
cd /srv/apps/feuerwehr
sudo ./scripts/validate.sh
sudo ./scripts/healthcheck.sh
sudo ./scripts/backup.sh
sudo ./scripts/update.sh
sudo ./scripts/uninstall.sh
```

`ENABLED_APPS` steuert `COMPOSE_PROFILES`. Gemeinsame PostgreSQL-Dienste starten nur mit den ausgewählten App-Profilen. Das Deaktivieren eines Profils entfernt keine Daten. Die Dienste Redis, PostgreSQL und Anwendungen erhalten keine unnötigen Hostports. Im Remote-Modus veröffentlicht Compose ausschließlich ausgewählte Anwendungsports und bindet sie an die konfigurierte VPN-IP.

## Verzeichnisse und Secrets

```text
/srv/apps/feuerwehr/
├── compose.yml, compose.proxy.yml / compose.remote.yml, .env
├── installation-info.txt    # Abschlussuebersicht ohne Kennwoerter, 0600
├── scripts/
├── secrets/                 # Verzeichnis 0700, nicht versioniert
├── postgres/data/           # Live-DB; niemals als reguläres Backup kopieren
├── keycloak/{providers,themes}/
├── wehrportal/storage/app/
├── matrix/data/             # homeserver.yaml, Signaturschlüssel, Medien
├── fluffychat/config.json
├── onlyoffice/{logs,data,lib}/
├── drupal/                  # Verwaltete Builddateien, Code liegt im Image
│   ├── files/               # Öffentliche Uploads
│   └── private/             # Private Dateien und Konfigurationsexporte
├── traefik/acme/acme.json
├── integrations/traefik/dynamic.yml
└── backups/
```

`.env` enthält nur Konfiguration und ist Modus `0600`. Geheimnisse werden einmalig mit `openssl rand` erzeugt und unter `secrets/` gespeichert; erneute Installationsläufe ersetzen sie nicht. Ein vorhandener WehrPortal-`APP_KEY` in `secrets/wehrportal_app_key` bleibt unverändert. Der Keycloak-Bootstrap-Administrator ist `KEYCLOAK_ADMIN_USER`; sein initiales Passwort liegt in `secrets/keycloak_admin_password`. Es wird absichtlich nicht im Terminal ausgegeben. Das leere `secrets/mail_smtp_password` muss bei WehrPortal mit dem SMTP-Passwort befüllt werden.

Compose-Dateisecrets sind auf einem einzelnen Docker-Host schreibgeschützte Datei-Mounts, aber keine verschlüsselten Swarm-Secrets. Docker-Daemon-Administratoren und Host-root können sie lesen. Passwörter, Matrix-Datenbankverbindung und JWT werden beim jeweiligen Containerstart in dessen Prozessumgebung geladen. Schütze daher den Host, Docker-Daemon und Backupzugriff.

Der Installer setzt Besitzerrechte nur für leere Datenverzeichnisse (PostgreSQL 70, Synapse 991, WehrPortal 82, Keycloak 1000, Drupal 33). Ändere diese Rechte nicht blind bei bestehenden Daten.

## Reverse-Proxy-Modi und TLS

Siehe [`docs/architecture.md`](docs/architecture.md), [`docs/installation.md`](docs/installation.md) und [`docs/reverse-proxy.md`](docs/reverse-proxy.md) für Topologie, Installation, Firewall, DNS, Routing und Betriebsgrenzen.

- **`own`**: eigener Traefik, Ports 80/443, HTTP-zu-HTTPS, ACME HTTP-01 standardmäßig. Die Router entstehen nur für aktivierte Dienste. Dashboard/API wird nicht veröffentlicht. Der Docker-Provider benötigt Zugriff auf `/var/run/docker.sock`; ein `:ro`-Mount macht die Docker-API nicht read-only. Dieser Zugriff ist als weitreichender Hostzugriff zu behandeln.
- **`same-host`**: kein eigener Traefik. Ein existierendes Docker-Netzwerk und dessen Zertifikatsresolver müssen explizit konfiguriert sein. `ENABLE_PROXY_ROUTES=false` erzeugt keine Router. Die optionale Integration verwendet eindeutige Router-Präfixe `fwstack-`.
- **`remote`**: keine Docker-API und keine gemeinsame Netzwerk-ID. Es entstehen eine VPN-IP-gebundene Compose-Portdatei sowie `integrations/traefik/dynamic.yml`. Diese Datei muss der entfernte Betreiber manuell in die bestehende Traefik-Dateikonfiguration übernehmen. Es werden keine externen Server geändert.

DNS-01 für den eigenen Traefik benötigt den Namen eines von Traefik unterstützten Providers und dessen Provider-Variablen. Über `--dns-env-file` wird eine Variablendatei nach `secrets/dns.env` mit Modus `0600` kopiert. Sie wird als Traefik-Umgebung eingebunden und nicht in Git gespeichert. HTTP-01 braucht öffentliche Erreichbarkeit auf Port 80.

## Anwendungen

### PostgreSQL und Redis

PostgreSQL verwendet standardmäßig `postgres:latest` (derzeit Major-Version 18) und hält `keycloak`, `wehrportal`, `synapse` und `drupal` mit getrennten Rollen. Ein Major-Version-Wechsel kann das vorhandene Datenverzeichnis nicht direkt wiederverwenden: `scripts/update.sh` stoppt die Anwendungen, erstellt zusätzlich zum regulären Backup einen vollständigen `pg_dumpall`-Dump, restauriert ihn in ein neues Cluster und schaltet erst nach Datenbank-/Rollenvergleich um. Die alte Datendatei bleibt für einen manuellen Rückweg erhalten. Das Upgrade benötigt zusätzliche Plattenkapazität und verursacht Downtime; ein Downgrade wird abgelehnt. `PGDATA` ist explizit gesetzt, damit der von PostgreSQL 18 geänderte Standardpfad die bestehende Mount-Struktur nicht verändert.

Redis `7.4.2-alpine` dient WehrPortal als Cache und Queue, nicht als fachliche Datenbank. Es ist intern und nicht persistent: Cache-Inhalte und noch nicht verarbeitete Queue-Jobs können bei Redis-Neustart verloren gehen.

### Keycloak

Keycloak `latest` nutzt PostgreSQL und die externe HTTPS-URL aus `KEYCLOAK_HOST`. Der Installer fragt `KEYCLOAK_REALM` ab (Standard `feuerwehr`, nicht `master`). `scripts/setup-apps.sh` legt über die HTTPS-Admin-API den Realm und je ausgewählter SSO-Anwendung einen verwalteten confidential Client `drupal`, `wehrportal` bzw. `synapse` an. Alle verwenden denselben Realm, aber getrennte Secrets und exakte Callbacks. Wiederholte Läufe erzeugen keine Duplikate und überschreiben keine fremden gleichnamigen Clients.

### WehrPortal

Das veröffentlichte WehrPortal-Release-Image verwendet Laravel 12/PHP 8.4, PostgreSQL und Redis für Cache/Queue. Der Stack betreibt einen separaten Queue-Worker; Migrationen und Scheduler werden vom Produktionscontainer beim Start ausgeführt. SMTP bleibt für die E-Mail-Magic-Links einschließlich des lokalen Notfallzugangs erforderlich.

Mit `ENABLED_APPS=keycloak,wehrportal` setzt der Installer automatisch `WEHRPORTAL_OIDC_ENABLED=true`, lädt die vorhandene OIDC-Erweiterung und konfiguriert sie nach fertigen Migrationen. Anmeldung: `https://<WEHRPORTAL_HOST>/anmelden`, Callback: exakt `https://<WEHRPORTAL_HOST>/auth/oidc/callback`. Der Client `wehrportal` erzwingt Authorization Code mit PKCE S256. Sein Secret liegt in `secrets/wehrportal_oidc_client_secret` und wird in WehrPortal über dessen Plugin-API mit `APP_KEY` verschlüsselt gespeichert; Keycloak-Adminzugangsdaten gelangen nicht in den Portalcontainer.

Anfangs bleibt der Magic-Link-Login parallel aktiv. Nur vorhandene aktive WehrPortal-Konten können beim ersten SSO-Login anhand einer **bestätigten** E-Mail-Adresse verknüpft werden; danach zählt Issuer + Subject. Automatische Kontoanlage und SSO-Zwang sind standardmäßig aus. Keine Admin-/Modulrechte werden aus Keycloak-Claims übernommen. Änderungen der Kontenpolitik in WehrPortal bleiben bei erneutem Setup erhalten; technische Verbindungswerte und SSO-Aktivierung werden vom Stack verwaltet.

Notfall: `WEHRPORTAL_OIDC_FORCE_DISABLED=true` in `.env` setzen und Webcontainer sowie Worker neu erstellen/deployen. Das entspricht WehrPortals `OIDC_FORCE_DISABLED`; erneutes Setup hebt den Schalter nicht auf. Lokale Systemadministratoren nutzen `/anmelden/lokal` mit Mail-Link, nicht mit einem lokalen Passwort. `php artisan oidc:disable` deaktiviert ebenfalls den IdP-Login, wird aber bei einem späteren Stack-Setup wieder durch die verwaltete Aktivierung ersetzt. Für eine dauerhafte Notfallabschaltung den Umgebungsschalter verwenden.

Ohne Keycloak bleibt das Portal bei lokalem Mail-Link-Login. Ein nicht kompatibles Image, fehlende Migrationen, falscher Callback oder nicht erreichbare öffentliche Keycloak-Endpunkte führen zu einem sichtbaren Setupfehler. Nach Korrektur `sudo ./scripts/setup-apps.sh` erneut ausführen. Ein normaler Containerneustart benötigt keinen Keycloak-Adminzugang. Uploads, lokale Storage-Dateien, Secrets einschließlich `wehrportal_app_key` und PostgreSQL müssen gemeinsam gesichert werden.

`WEHRPORTAL_ADMIN_EMAILS` ist eine ausdrückliche Liste initialer Administrator-E-Mail-Adressen. WehrPortals `app:ensure-admins` aktiviert bzw. erstellt diese Konten beim Start; halte die Liste deshalb eng und ändere sie nach Bedarf.

### Matrix Synapse und FluffyChat Web

Synapse `latest` speichert Medien, Signaturschlüssel und Konfiguration unter `matrix/data`. Der Startwrapper erzeugt fehlende Konfiguration und setzt bei jedem Start PostgreSQL, öffentliche Basis-URL und die verwalteten SSO-Werte. Statistiken und offene Registrierung sind deaktiviert. Federation ist standardmäßig aus; `MATRIX_FEDERATION=true` erlaubt Synapse Federation, ersetzt aber keine DNS-, Firewall- oder Well-known-Konfiguration.

Mit `ENABLED_APPS=keycloak,matrix` setzt der Installer automatisch `MATRIX_OIDC_ENABLED=true`. Der Client `synapse` verwendet Authorization Code mit PKCE S256 und exakt `https://<MATRIX_HOST>/_synapse/client/oidc/callback`. Das Secret liegt in `secrets/synapse_oidc_client_secret`; Synapse liest es über `client_secret_path`, nicht als Klartext in der YAML. Keycloak muss vom Host und Synapse über seine öffentliche HTTPS-Domain erreichbar sein.

FluffyChat Web `latest` wird als statischer Webclient aus `ghcr.io/etkecc/fluffychat-web` bereitgestellt. Seine `config.json` setzt `defaultHomeserver` auf `MATRIX_HOST`. Öffne `https://<FLUFFYCHAT_HOST>/`, wähle den vorkonfigurierten Homeserver und dort die angebotene SSO-/Keycloak-Anmeldung. Der Browser wechselt zu Keycloak und kehrt nach dem Login zu FluffyChat zurück. Synapse liefert die verfügbaren Loginverfahren; FluffyChat braucht keinen eigenen Keycloak-Client und kein Clientsecret. Andere Matrix-Clients müssen denselben Homeserver und SSO unterstützen.

Beim ersten SSO-Login entsteht ein normales Matrix-Konto; gegebenenfalls wird der gewünschte Benutzername bestätigt. Die Identität wird über Keycloaks stabile `sub`-Kennung zugeordnet. Bestehende Matrix-Konten werden nicht automatisch verknüpft, auch nicht bei gleichem Benutzernamen oder gleicher E-Mail. Bei belegten Namen erzeugt Synapse einen anderen Matrix-Namen, beispielsweise mit Ziffernsuffix. Keycloak-Administratoren werden nicht zu Matrix-Administratoren. Lokaler Passwortlogin bleibt für separat eingerichtete lokale Konten verfügbar; der Installer erzeugt keinen lokalen Matrix-Admin.

Nach Änderungen an Domains, Realm oder OIDC-Umgebungswerten zuerst `sudo ./scripts/setup-apps.sh` zum Abgleich des Keycloak-Clients ausführen und Synapse neu erstellen/deployen; danach das Setup zur Bereitschaftsprüfung erneut aufrufen. Bei geänderten Umgebungswerten reicht `docker compose restart` nicht. `MATRIX_OIDC_ENABLED=false` entfernt beim nächsten Start nur den verwalteten Keycloak-Provider; fremde Provider bleiben erhalten. Gemeinsames Logout, automatische Rollenvergabe und Matrix-Kontomigration sind nicht eingerichtet.

`MATRIX_SERVER_NAME` ist die Matrix-Identität und kann von `MATRIX_HOST` abweichen. In diesem Fall müssen die Matrix-`/.well-known`-Dokumente und DNS gezielt eingerichtet werden. Der Stack erzeugt sie nicht.

### ONLYOFFICE

ONLYOFFICE Community `latest` nutzt die offiziellen persistenten Pfade `/var/log/onlyoffice`, `/var/www/onlyoffice/Data` und `/var/lib/onlyoffice`. JWT ist aktiviert. Mit `ENABLED_APPS=wehrportal,onlyoffice` konfiguriert `scripts/setup-apps.sh` automatisch WehrPortals vorhandenes Dateien-Modul, unabhängig von Keycloak:

- Anbieter `onlyoffice`, Browseradresse `https://<ONLYOFFICE_HOST>`, interne Adresse `http://onlyoffice`.
- Download-/Callback-Basis `https://<WEHRPORTAL_HOST>` und dasselbe `secrets/onlyoffice_jwt_secret` wie im Document Server.
- Speicherung über `OfficeSettings::save`, mit `APP_KEY` verschlüsseltem Secret in der Portal-Datenbank. Keine Secret-Ausgabe und kein zusätzlicher Schlüssel.

Das Setup wartet auf Migrationen und ONLYOFFICE-Bereitschaft; Installation, Update und Restore verwenden denselben Ablauf. Wiederholte Läufe gleichen technische URLs und Secret ab, erhalten aber vorhandene Format-/Bearbeitungsbeschränkungen, Modulaktivierung und Benutzerrechte. Das Modul muss in WehrPortal aktiviert und für die gewünschten Nutzer freigegeben sein. Die vorhandene Office-Schnittstelle prüft signierte Downloads und Save-Callbacks und speichert Änderungen als Dateiversionen.

Browser müssen die öffentliche ONLYOFFICE-Adresse erreichen; ONLYOFFICE muss die öffentliche Portal-Adresse über gültiges HTTPS erreichen (gegebenenfalls Hairpin-NAT). Keine vorgeschaltete Login-Middleware vor `/dateien/office/onlyoffice/`. Private Zieladressen werden im produktiven Document Server nicht pauschal freigegeben. Bei Netzwerk-/TLS-Fehlern die Routen korrigieren, bei geänderten Umgebungswerten Container neu erstellen/deployen und `sudo ./scripts/setup-apps.sh` erneut ausführen. Änderungen an verwalteten URLs/Secret nur in der Portaloberfläche werden beim nächsten Setup ersetzt. Wird eine Anwendung abgewählt, werden gespeicherte Office-Einstellungen nicht automatisch gelöscht.

### Drupal

Drupal wird mit `drupal` in `ENABLED_APPS` ausgewählt und beim ersten Start automatisch installiert. `DRUPAL_HOST` legt die öffentliche Adresse fest.

Der lokale Build verwendet Drupal **11.4.11** (Basisimage zusätzlich per Digest gepinnt), Drush **13.8.0** und das stabile OpenID-Connect-Modul **1.6.0** mit generischem Keycloak-Provider. Alle PHP-Abhängigkeiten sind in `drupal/composer.lock` festgeschrieben; keine Alpha-Abhängigkeit des separaten Keycloak-Moduls. Updates dieser Komponenten erfolgen bewusst über Builddateien und Lockfile, nicht durch automatische Major-Upgrades. In Swarm wird auf dem Installationsknoten gebaut, auf dem alle Dienste platziert sind.

Die Datenbank `drupal` und Rolle `drupal` liegen im gemeinsamen PostgreSQL. `scripts/setup-drupal.sh` ergänzt sie auch in bestehenden Clustern und aktiviert `pg_trgm`. Beim ersten Start installiert Drush die Site; danach werden Schema-Updates und die verwaltete OIDC-Konfiguration angewendet. Öffentliche Dateien liegen unter `drupal/files`, private Dateien unter `drupal/private`.

Mit `ENABLED_APPS=keycloak,drupal` wird `DRUPAL_OIDC_ENABLED=true` automatisch gesetzt. Anmeldung über `https://<DRUPAL_HOST>/user/login` mit dem OpenID-Connect-Button; Callback ist exakt `https://<DRUPAL_HOST>/openid-connect/generic`. Keycloak-Konten benötigen eine E-Mail-Adresse. Neue SSO-Nutzer erhalten nur normale Benutzerrechte, keine Redaktions-/Adminrolle. Bestehende Konten werden nicht allein anhand gleicher E-Mail-Adressen verknüpft. Rollen werden bewusst in Drupal vergeben; das Keycloak-Bootstrap-Administratorkonto ist kein Drupal-Admin.

Der lokale Notfalladministrator heißt `siteadmin`; sein initiales Passwort steht in `secrets/drupal_admin_password`. Nach Passwortänderungen in Drupal ist diese Datei kein aktueller Passwortnachweis; Neustarts setzen das Passwort nicht zurück. Ohne Keycloak bleibt Drupal mit lokalem Login verfügbar. OIDC-Client-Secret, DB-Passwort und Hash-Salt werden aus Secret-Dateien gelesen; das OIDC-Secret landet nicht in Drupal-Konfigurationsexporten.

Bei DNS-/TLS-/Proxy-Fehlern bricht der OIDC-Bootstrap sichtbar ab. Nach Korrektur `sudo ./scripts/setup-apps.sh` erneut aufrufen. Im Remote-Proxy-Modus muss die generierte Proxy-Konfiguration vorher übertragen werden. Die Bootstrap-Zugangsdaten müssen für erneute Client-Anpassungen weiterhin gültig sein. Gemeinsames Logout und automatische Keycloak-Rollen-Synchronisierung sind nicht eingerichtet.

## Sicherung, Wiederherstellung, Update und Entfernen

Siehe [`docs/backup-restore.md`](docs/backup-restore.md), [`docs/migration.md`](docs/migration.md) und [`docs/security.md`](docs/security.md).

- Backup: `scripts/backup.sh` stoppt kurz die laufenden App-Container, erstellt konsistente PostgreSQL-Custom-Dumps und sichert Dateien, Konfigurationen und Secrets. Das Backup enthält Geheimnisse und ist Modus `0600`; sichere es zusätzlich verschlüsselt und extern. Redis-Daten sind nicht enthalten.
- Restore: nur auf einem Zielsystem ausführen, dessen Daten überschrieben werden dürfen. Es wird interaktiv bestätigt und nicht automatisch während der Installation ausgelöst.
- Update: `scripts/update.sh` aktualisiert zuerst `compose.yml` und die verwalteten Skripte aus `main` und startet sich nach einem eigenen Update neu. Danach sichert es die Daten und zieht die konfigurierten Images. Bei einem PostgreSQL-Major-Wechsel wird zusätzlich ein vollständiger Cluster-Dump erstellt und in ein neues Cluster migriert. WehrPortal-Migrationen laufen beim Start des Produktionscontainers.
- Deinstallation: `scripts/uninstall.sh` entfernt standardmäßig nur Compose-Container und Stack-Netzwerke. Nur `--delete-data` plus Eingabe des exakten Pfads löscht Backups, Secrets und persistente Daten.

## Fehlerbehebung und bekannte Einschränkungen

- `scripts/validate.sh` prüft Compose-Konfiguration und Dateirechte; `scripts/healthcheck.sh` zeigt Compose-Zustände.
- WehrPortal benötigt ein verfügbares veröffentlichtes Image; Synapse erzeugt seine Konfiguration beim ersten Start. Fehlerbehebung: [`docs/troubleshooting.md`](docs/troubleshooting.md).
- Der Installer prüft keine DNS-Ziel-IP gegen den Host. Das WehrPortal-Image wird vor Hoständerungen in GHCR geprüft; andere Registry-Erreichbarkeit wird nicht vorab getestet. Betriebssystempakete werden nicht installiert.
- Matrix-Federation, externe SMTP-Erreichbarkeit und produktive DNS-/TLS-/Traefik-VPN-Routen benötigen separate Integrationstests.
- Compose verwendet überwiegend bewegliche `latest`-Tags. Ein Update kann deshalb auch inkompatible Major-Releases anderer Anwendungen einführen; prüfe regelmäßig Release-Hinweise und halte externe, verschlüsselte Backups bereit. PostgreSQL-Downgrades bleiben manuell.

## Prüfungen

```bash
tests/run.sh
```

Das Testskript führt Bash-Syntaxprüfung, Python-Syntaxprüfung, ShellCheck (wenn installiert), Installer-Dry-Run-/Eingabetests, Proxy-Konfigurationstests sowie lokale Compose-Modellvalidierung aus. Es benötigt für Compose-Validierung Docker Compose v2, aber keinen laufenden Docker-Daemon. Keine echten Container oder externen Dienste werden gestartet.

Die Installer-Tests prüfen außerdem Terminal-Eingaben mit Wiederholung bei Fehlern, relevante/übersprungene Fragen und Abschlussübersichten ohne Secret-Inhalte. `tests/integration-installer.sh` führt den vollständigen Installer zusätzlich als root in einem wegwerfbaren Container aus: ohne Netzwerk oder Zugriff auf den Host-Docker-Daemon, mit einer simulierten Docker-CLI. Geprüft werden `--no-start`, Start-/Fehlerzustände, wiederholte Läufe, sichere Berichtsspeicherung und die interaktive Bestätigung; dies ist kein realer Deploymenttest.

`tests/integration-drupal.sh` prüft optional mit laufendem Docker-Daemon den Image-Build, die idempotente PostgreSQL-/Keycloak-Provisionierung, echten HTTPS-OIDC-Login, Benutzerrechte, lokalen Notfallzugang und geheimnisfreie Konfigurationsexporte. Es veröffentlicht keine Hostports und entfernt seine Testcontainer nach Abschluss.

`tests/integration-synapse.sh` ergänzt echte HTTPS-SSO-Anmeldungen gegen Synapse und Keycloak, die Matrix-Login-Token-Einlösung, getrennte lokale/SSO-Konten, gesperrte offene Registrierung sowie den erneuten Login nach Datenbank-Restore. Dies prüft das von FluffyChat verwendete Protokoll, nicht dessen Browseroberfläche.

`tests/integration-wehrportal.sh` ergänzt das aktuelle WehrPortal-Image, realen HTTPS-Code-/PKCE-Login, verschlüsselte Settings, Ablehnung unbestätigter/inaktiver/unbekannter Konten, fehlende Adminrechte, Notfallschalter, Erhalt der Kontenpolitik sowie Datenbank-Restore und erneuten Login. Der Mail-Link-Versand verwendet einen Test-Logtransport, keinen externen SMTP-Server. Ein ausschließlich in Testcontainer eingehängter Netzwerkadapter lenkt den HTTP-Transport auf den isolierten Proxy; TLS, Tokenaustausch und Signaturprüfung bleiben real. Ohne diesen Adapter wird die private IdP-Adresse ausdrücklich abgelehnt. Produktive DNS-/TLS-/Hairpin-Erreichbarkeit muss separat geprüft werden.

`tests/integration-office.sh` ergänzt den echten ONLYOFFICE Document Server: verschlüsselte gemeinsame JWT-Konfiguration, Wiederholung/Restore ohne Verlust von Richtlinien, signierte Dateidownloads, reale TXT/DOCX-Konvertierung und Save-Callback mit neuer Dateiversion. Ungültige Hosts, kurze Secrets und falsche Signaturen werden abgelehnt. Nur der isolierte Testserver erlaubt private Zieladressen und vertraut der Test-CA; die produktive Konfiguration lockert diese Prüfungen nicht. Die Browser-Editoroberfläche wird damit nicht automatisiert bedient.
