# Feuerwehr-Stack

Modularer Docker-Compose-Stack für eine einzelne Debian-/Ubuntu-Maschine. Der Installer legt Konfiguration, Secrets und persistente Anwendungsdaten unter einem frei wählbaren Pfad ab (Standard: `/srv/apps/feuerwehr`). Docker Swarm wird nicht benötigt.

## Status und Grenzen

| Bestandteil | Status |
| --- | --- |
| Installer, Profile, sichere lokale Secrets und Compose-Konfiguration | Implementiert; Syntax- und Compose-Modelltests vorhanden |
| Eigener Traefik, vorhandener Traefik auf demselben Docker-Host, entfernter Traefik über VPN | Konfiguration wird je Modus erzeugt; produktive DNS-/TLS-/VPN-Verbindungen hier nicht getestet |
| PostgreSQL mit getrennten Datenbanken/Rollen | Implementiert; `scripts/update.sh` erstellt vor Major-Upgrades einen vollständigen Dump und migriert das Cluster logisch |
| Keycloak | Container und Bootstrap-Zugang vorbereitet; Realm und OIDC-Clients werden bewusst manuell eingerichtet |
| WehrPortal | Produktions-Image `ghcr.io/timux/wehrportal:latest` (Tag in `.env`), PostgreSQL, Redis, Queue-Worker, persistentes Storage und SMTP |
| Matrix Synapse und FluffyChat Web | Synapse-Konfiguration wird beim ersten Start erzeugt und auf PostgreSQL gesetzt; Registrierung ist aus |
| ONLYOFFICE Docs | JWT wird aus einer Secret-Datei geladen; Containerpfade folgen der offiziellen Community-Image-Dokumentation |
| GRAV | LinuxServer-Image mit persistentem `/config`-Mount |

**Noch nicht integriert bzw. nicht als funktionsfähig zugesichert:** WehrPortal-OIDC/Keycloak, Matrix-OIDC, Keycloak-SSO für GRAV, WehrPortal/ONLYOFFICE-Dokumentbearbeitung samt Save-Callbacks sowie automatische Matrix-`/.well-known`-Dateien. Die Integrationen benötigen eigene Änderungen und Tests. OIDC-Anmeldung ersetzt nicht WehrPortals fachliche Mitglieder- und Rechteverwaltung. Prüfe insbesondere Login, E-Mailversand, Backups, Wiederherstellung und Updatepfade vor produktiver Nutzung.

Die Repository-Tests starten keine Container und testen keine externen Dienste. Die tatsächliche Installation, Image-Pulls, Container-Healthchecks und Anwendungsmigrationen wurden nicht ausgeführt.

## Voraussetzungen

- Unterstütztes Betriebssystem laut Installer: Debian, Ubuntu oder Raspbian; Docker Engine und Docker Compose Plugin v2 müssen bereits installiert und erreichbar sein. Der Installer installiert Docker nicht.
- Root-Rechte (`sudo`) für Installation und Host-Verzeichnisse.
- Für WehrPortal muss das Image `ghcr.io/timux/wehrportal:latest` in GHCR verfügbar sein; explizite Release-Tags werden zusätzlich über GitHub verifiziert.
- Mindestens 5 GiB freier Speicher; bei ausgewähltem ONLYOFFICE mindestens 8 GiB. ONLYOFFICE empfiehlt außerdem mindestens 4 GiB RAM.
- DNS-Einträge für alle aktivierten Anwendungen. Beim eigenen Traefik müssen TCP 80 und 443 öffentlich zum Host führen.
- Für WehrPortal: SMTP-Zugangsdaten. Der Installer ermittelt das neueste GitHub-Release und prüft, ob das dazugehörige GHCR-Image verfügbar ist. Er speichert anschließend den konkreten Versionstag in `.env`; ein nicht veröffentlichtes Image führt zum Abbruch.

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
2. Gewünschte Anwendungen im Schlüssel `ENABLED_APPS` angeben: `keycloak`, `wehrportal`, `matrix`, `onlyoffice`, `grav`. Ohne Konfigurationsdatei fragt der Installer interaktiv für jede Anwendung nach, ob sie installiert werden soll.
3. Konfiguration prüfen:

   ```bash
   sudo ./install.sh --config ./config/installation.env.example --dry-run
   ```

4. Installieren (der Installer zeigt die Einstellungen und fragt vor Änderungen nach):

   ```bash
   sudo ./install.sh --config ./config/installation.env.example
   ```

   Alternativ ohne Konfigurationsdatei interaktiv: `sudo ./install.sh`. Dabei werden Primärdomain (mit Endung), App-Auswahl und je aktivierter Anwendung das DNS-Subdomain-Label abgefragt. Standardwerte sind `login` (Keycloak), `portal` (WehrPortal), `matrix` (Synapse), `messenger` (FluffyChat), `docs` (ONLYOFFICE) und `www` (Website). Für Konfigurationsdateien bleiben die `*_HOST`-Werte vollständige Domainnamen. Der Pfad kann mit `--path /anderer/pfad` überschrieben werden. `--no-start` legt Dateien und Secrets an, startet aber keine Container.

Der Installer kontrolliert Betriebssystem-ID, Root-Rechte, Docker/Compose-Erreichbarkeit, Speicherplatz und bei eigenem Traefik die Hostports. Bei vorhandenen Traefik-Netzwerken prüft er den exakten Netzwerknamen. DNS-Auflösung wird als Warnung angezeigt, wenn `getent` verfügbar ist. Er verändert keine Docker-Netzwerke und überschreibt keine vorhandenen Secret-Dateien. Ein nicht leeres Ziel ohne Stack-`.env` wird abgelehnt.
Bei erneuten Installationsläufen aktualisiert der Installer die Stack-Dateien `compose.yml` und `scripts/*` automatisch aus dem Repository-Stand. Vor dem Ersetzen von `compose.yml` wird bei Änderungen eine Sicherung als `compose.yml.bak` erzeugt.
Zusätzlich fragt der Installer ein Gesamtbudget für RAM (`STACK_MAX_MEMORY_MB`) und CPU (`STACK_MAX_CPUS`) ab, verteilt es auf die aktiven Dienste und schreibt die resultierenden `MEM_*`-/`CPU_*`-Werte in `.env`.
Findet der Installer bereits PostgreSQL-Daten, führt er den Start über `scripts/update.sh` aus, damit ein Major-Version-Wechsel zuerst gesichert und migriert wird.

WehrPortal wird standardmäßig als `ghcr.io/timux/wehrportal:latest` gestartet; der Installer prüft, ob dieses Image in GHCR verfügbar ist, und schreibt `WEHRPORTAL_IMAGE_TAG=latest` in `.env`. Ein expliziter veröffentlichter Versionstag bleibt möglich und wird über GitHub und GHCR verifiziert.

WehrPortal ist eine Neuinstallation ohne Übernahme von OpenWehr-Bestandsdaten. Ein vorhandenes Stack-Verzeichnis mit OpenWehr-Konfiguration oder PostgreSQL-Daten wird nicht überschrieben oder migriert; für WehrPortal ist ein separater, leerer Installationspfad erforderlich. Die alte Installation und ihre Daten bleiben für einen manuellen Rückweg erhalten.

Bei `--no-start` müssen Synapse-Konfiguration und Dienste manuell gestartet werden. Die Matrix-Dateien werden beim normalen Installationslauf mit `docker compose run` vor dem Stack-Start erzeugt.

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
├── scripts/
├── secrets/                 # 0600, nicht versioniert
├── postgres/data/           # Live-DB; niemals als reguläres Backup kopieren
├── keycloak/{providers,themes}/
├── wehrportal/storage/app/
├── matrix/data/             # homeserver.yaml, Signaturschlüssel, Medien
├── fluffychat/config.json
├── onlyoffice/{logs,data,lib}/
├── grav/config/
├── traefik/acme/acme.json
├── integrations/traefik/dynamic.yml
└── backups/
```

`.env` enthält nur Konfiguration und ist Modus `0600`. Geheimnisse werden einmalig mit `openssl rand` erzeugt und unter `secrets/` gespeichert; erneute Installationsläufe ersetzen sie nicht. Ein vorhandener WehrPortal-`APP_KEY` in `secrets/wehrportal_app_key` bleibt unverändert. Der Keycloak-Bootstrap-Administrator ist `KEYCLOAK_ADMIN_USER`; sein initiales Passwort liegt in `secrets/keycloak_admin_password`. Es wird absichtlich nicht im Terminal ausgegeben. Das leere `secrets/mail_smtp_password` muss bei WehrPortal mit dem SMTP-Passwort befüllt werden.

Compose-Dateisecrets sind auf einem einzelnen Docker-Host schreibgeschützte Datei-Mounts, aber keine verschlüsselten Swarm-Secrets. Docker-Daemon-Administratoren und Host-root können sie lesen. Passwörter, Matrix-Datenbankverbindung und JWT werden beim jeweiligen Containerstart in dessen Prozessumgebung geladen. Schütze daher den Host, Docker-Daemon und Backupzugriff.

Der Installer setzt Besitzerrechte nur für leere Datenverzeichnisse (PostgreSQL 70, Synapse 991, WehrPortal 82, Keycloak/GRAV 1000). Ändere diese Rechte nicht blind bei bestehenden Daten.

## Reverse-Proxy-Modi und TLS

Siehe [`docs/architecture.md`](docs/architecture.md), [`docs/installation.md`](docs/installation.md) und [`docs/reverse-proxy.md`](docs/reverse-proxy.md) für Topologie, Installation, Firewall, DNS, Routing und Betriebsgrenzen.

- **`own`**: eigener Traefik, Ports 80/443, HTTP-zu-HTTPS, ACME HTTP-01 standardmäßig. Die Router entstehen nur für aktivierte Dienste. Dashboard/API wird nicht veröffentlicht. Der Docker-Provider benötigt Zugriff auf `/var/run/docker.sock`; ein `:ro`-Mount macht die Docker-API nicht read-only. Dieser Zugriff ist als weitreichender Hostzugriff zu behandeln.
- **`same-host`**: kein eigener Traefik. Ein existierendes Docker-Netzwerk und dessen Zertifikatsresolver müssen explizit konfiguriert sein. `ENABLE_PROXY_ROUTES=false` erzeugt keine Router. Die optionale Integration verwendet eindeutige Router-Präfixe `fwstack-`.
- **`remote`**: keine Docker-API und keine gemeinsame Netzwerk-ID. Es entstehen eine VPN-IP-gebundene Compose-Portdatei sowie `integrations/traefik/dynamic.yml`. Diese Datei muss der entfernte Betreiber manuell in die bestehende Traefik-Dateikonfiguration übernehmen. Es werden keine externen Server geändert.

DNS-01 für den eigenen Traefik benötigt den Namen eines von Traefik unterstützten Providers und dessen Provider-Variablen. Über `--dns-env-file` wird eine Variablendatei nach `secrets/dns.env` mit Modus `0600` kopiert. Sie wird als Traefik-Umgebung eingebunden und nicht in Git gespeichert. HTTP-01 braucht öffentliche Erreichbarkeit auf Port 80.

## Anwendungen

### PostgreSQL und Redis

PostgreSQL verwendet standardmäßig `postgres:latest` (derzeit Major-Version 18) und hält `keycloak`, `wehrportal` und `synapse` mit getrennten Rollen. Ein Major-Version-Wechsel kann das vorhandene Datenverzeichnis nicht direkt wiederverwenden: `scripts/update.sh` stoppt die Anwendungen, erstellt zusätzlich zum regulären Backup einen vollständigen `pg_dumpall`-Dump, restauriert ihn in ein neues Cluster und schaltet erst nach Datenbank-/Rollenvergleich um. Die alte Datendatei bleibt für einen manuellen Rückweg erhalten. Das Upgrade benötigt zusätzliche Plattenkapazität und verursacht Downtime; ein Downgrade wird abgelehnt. `PGDATA` ist explizit gesetzt, damit der von PostgreSQL 18 geänderte Standardpfad die bestehende Mount-Struktur nicht verändert.

Redis `7.4.2-alpine` dient WehrPortal als Cache und Queue, nicht als fachliche Datenbank. Es ist intern und nicht persistent: Cache-Inhalte und noch nicht verarbeitete Queue-Jobs können bei Redis-Neustart verloren gehen.

### Keycloak

Keycloak `latest` nutzt PostgreSQL und die externe HTTPS-URL aus `KEYCLOAK_HOST`. Nach dem ersten Start: anmelden, Realm und getrennte Clients für tatsächlich integrierte Anwendungen anlegen und Redirect-URIs eng begrenzen. WehrPortal-OIDC, Matrix-OIDC und GRAV-SSO sind derzeit nicht fertig integriert. Ein erfolgreicher Login darf keine fachlichen Administratorrechte implizieren.

### WehrPortal

Das veröffentlichte WehrPortal-Release-Image verwendet Laravel 12/PHP 8.4, PostgreSQL und Redis für Cache/Queue. Der Stack betreibt einen separaten Queue-Worker; Migrationen und Scheduler werden vom Produktionscontainer beim Start ausgeführt. Die Anmeldung verwendet E-Mail-Magic-Links, nicht OIDC, daher ist SMTP erforderlich.

WehrPortal-OIDC und ONLYOFFICE-Callbacks sind nicht implementiert. Uploads, lokale Storage-Dateien und PostgreSQL müssen gemeinsam gesichert werden.

`WEHRPORTAL_ADMIN_EMAILS` ist eine ausdrückliche Liste initialer Administrator-E-Mail-Adressen. WehrPortals `app:ensure-admins` aktiviert bzw. erstellt diese Konten beim Start; halte die Liste deshalb eng und ändere sie nach Bedarf.

### Matrix Synapse und FluffyChat Web

Synapse `latest` speichert Medien und Konfiguration unter `matrix/data`; die beim ersten Start erzeugte Konfiguration wird auf PostgreSQL gesetzt, Statistiken und offene Registrierung sind deaktiviert. Federation ist standardmäßig aus; `MATRIX_FEDERATION=true` erlaubt Synapse Federation, ersetzt aber keine DNS-, Firewall- oder Well-known-Konfiguration.

FluffyChat Web `latest` wird als statischer Webclient aus `ghcr.io/etkecc/fluffychat-web` bereitgestellt. Seine `config.json` setzt `defaultHomeserver` auf `MATRIX_HOST`. FluffyChat-SSO/OIDC mit Synapse und Keycloak ist nicht fertig eingerichtet und darf nicht als verfügbar angenommen werden.

`MATRIX_SERVER_NAME` ist die Matrix-Identität und kann von `MATRIX_HOST` abweichen. In diesem Fall müssen die Matrix-`/.well-known`-Dokumente und DNS gezielt eingerichtet werden. Der Stack erzeugt sie nicht.

### ONLYOFFICE und GRAV

ONLYOFFICE Community `latest` nutzt die offiziellen persistenten Pfade `/var/log/onlyoffice`, `/var/www/onlyoffice/Data` und `/var/lib/onlyoffice`. JWT ist aktiviert. Eine vollständige Einbindung braucht eine Anwendung, die Dokumente von außen abrufbar macht, JWT prüft und Save-Callbacks verarbeitet; das ist in WehrPortal derzeit nicht implementiert.

GRAV wird mit LinuxServer `latest` und persistentem `/config` betrieben. Der Adminbereich ist nicht automatisch durch Keycloak geschützt. GRAV-SSO ist nicht integriert.

## Sicherung, Wiederherstellung, Update und Entfernen

Siehe [`docs/backup-restore.md`](docs/backup-restore.md), [`docs/migration.md`](docs/migration.md) und [`docs/security.md`](docs/security.md).

- Backup: `scripts/backup.sh` stoppt kurz die laufenden App-Container, erstellt konsistente PostgreSQL-Custom-Dumps und sichert Dateien, Konfigurationen und Secrets. Das Backup enthält Geheimnisse und ist Modus `0600`; sichere es zusätzlich verschlüsselt und extern. Redis-Daten sind nicht enthalten.
- Restore: nur auf einem Zielsystem ausführen, dessen Daten überschrieben werden dürfen. Es wird interaktiv bestätigt und nicht automatisch während der Installation ausgelöst.
- Update: `scripts/update.sh` aktualisiert zuerst `compose.yml` und die verwalteten Skripte aus `main` und startet sich nach einem eigenen Update neu. Danach sichert es die Daten und zieht die konfigurierten Images. Bei einem PostgreSQL-Major-Wechsel wird zusätzlich ein vollständiger Cluster-Dump erstellt und in ein neues Cluster migriert. WehrPortal-Migrationen laufen beim Start des Produktionscontainers.
- Deinstallation: `scripts/uninstall.sh` entfernt standardmäßig nur Compose-Container und Stack-Netzwerke. Nur `--delete-data` plus Eingabe des exakten Pfads löscht Backups, Secrets und persistente Daten.

## Fehlerbehebung und bekannte Einschränkungen

- `scripts/validate.sh` prüft Compose-Konfiguration und Dateirechte; `scripts/healthcheck.sh` zeigt Compose-Zustände.
- WehrPortal- und Synapse-Container starten nach `--no-start` erst, wenn ein veröffentlichtes WehrPortal-Image verfügbar ist bzw. `homeserver.yaml` vorhanden ist. Fehlermeldungen und manuelle Vorbereitung: [`docs/troubleshooting.md`](docs/troubleshooting.md).
- Der Installer prüft keine DNS-Ziel-IP gegen den Host. Das WehrPortal-Image wird vor Hoständerungen in GHCR geprüft; andere Registry-Erreichbarkeit wird nicht vorab getestet. Betriebssystempakete werden nicht installiert.
- Matrix-Federation, OIDC, ONLYOFFICE-Dokument-Callbacks, GRAV-SSO, externe SMTP-Erreichbarkeit und Traefik-VPN-Routen benötigen separate Integrationstests.
- Compose verwendet überwiegend bewegliche `latest`-Tags. Ein Update kann deshalb auch inkompatible Major-Releases anderer Anwendungen einführen; prüfe regelmäßig Release-Hinweise und halte externe, verschlüsselte Backups bereit. PostgreSQL-Downgrades bleiben manuell.

## Prüfungen

```bash
tests/run.sh
```

Das Testskript führt Bash-Syntaxprüfung, Python-Syntaxprüfung, ShellCheck (wenn installiert), Installer-Dry-Run-/Eingabetests, Proxy-Konfigurationstests sowie lokale Compose-Modellvalidierung aus. Es benötigt für Compose-Validierung Docker Compose v2, aber keinen laufenden Docker-Daemon. Keine echten Container oder externen Dienste werden gestartet.
