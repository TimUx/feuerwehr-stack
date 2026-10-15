# Feuerwehr-Stack

Modularer Docker-Compose-Stack für eine einzelne Debian-/Ubuntu-Maschine. Der Installer legt Konfiguration, Secrets und persistente Anwendungsdaten unter einem frei wählbaren Pfad ab (Standard: `/srv/apps/feuerwehr`). Docker Swarm wird nicht benötigt.

## Status und Grenzen

| Bestandteil | Status |
| --- | --- |
| Installer, Profile, sichere lokale Secrets und Compose-Konfiguration | Implementiert; Syntax- und Compose-Modelltests vorhanden |
| Eigener Traefik, vorhandener Traefik auf demselben Docker-Host, entfernter Traefik über VPN | Konfiguration wird je Modus erzeugt; produktive DNS-/TLS-/VPN-Verbindungen hier nicht getestet |
| PostgreSQL mit getrennten Datenbanken/Rollen | Implementiert; Datenbankstart und Migrationen müssen auf dem Zielhost geprüft werden |
| Keycloak | Container und Bootstrap-Zugang vorbereitet; Realm und OIDC-Clients werden bewusst manuell eingerichtet |
| OpenWehr | Produktivmodus, Redis, Worker, Scheduler-Unterstützung, persistentes Storage und SMTP-Umgebung vorbereitet; baut den geprüften OpenWehr-Quellstand |
| Matrix Synapse und Element | Synapse-Konfiguration wird beim ersten Start erzeugt und auf PostgreSQL gesetzt; Registrierung ist aus |
| ONLYOFFICE Docs | JWT wird aus einer Secret-Datei geladen; Containerpfade folgen der offiziellen Community-Image-Dokumentation |
| GRAV | LinuxServer-Image mit persistentem `/config`-Mount |

**Noch nicht integriert bzw. nicht als funktionsfähig zugesichert:** OpenWehr-OIDC/Keycloak, Matrix-OIDC, Keycloak-SSO für GRAV, OpenWehr/ONLYOFFICE-Dokumentbearbeitung samt Save-Callbacks sowie automatische Matrix-`/.well-known`-Dateien. Die Integrationen benötigen eigene Änderungen und Tests. OIDC-Anmeldung ersetzt nicht OpenWehrs fachliche Mitglieder- und Rechteverwaltung. Prüfe insbesondere Login, E-Mailversand, Backups, Wiederherstellung und Updatepfade vor produktiver Nutzung.

Die Repository-Tests starten keine Container und testen keine externen Dienste. Auf diesem Host wurden ShellCheck, Bash-/Python-Syntax, Dry-Run-/Eingabetests sowie `docker compose config` für alle Proxy-Modi ausgeführt. Die tatsächliche Installation, Image-Pulls, Container-Healthchecks und Anwendungsmigrationen wurden nicht ausgeführt.

## Voraussetzungen

- Unterstütztes Betriebssystem laut Installer: Debian, Ubuntu oder Raspbian; Docker Engine und Docker Compose Plugin v2 müssen bereits installiert und erreichbar sein. Der Installer installiert Docker nicht.
- Root-Rechte (`sudo`) für Installation und Host-Verzeichnisse.
- Mindestens 5 GiB freier Speicher; bei ausgewähltem ONLYOFFICE mindestens 8 GiB. ONLYOFFICE empfiehlt außerdem mindestens 4 GiB RAM.
- DNS-Einträge für alle aktivierten Anwendungen. Beim eigenen Traefik müssen TCP 80 und 443 öffentlich zum Host führen.
- Für OpenWehr: SMTP-Zugangsdaten. Der Installer lädt standardmäßig den festgelegten OpenWehr-Quellcommit von GitHub, wenn kein Quellverzeichnis angegeben wird.

Lege vorab beispielsweise folgende DNS-Einträge an (nur aktivierte Dienste sind erforderlich):

```text
id.feuerwehr.example.de       -> Reverse Proxy
wehr.feuerwehr.example.de     -> Reverse Proxy
matrix.feuerwehr.example.de   -> Reverse Proxy
chat.feuerwehr.example.de     -> Reverse Proxy
docs.feuerwehr.example.de     -> Reverse Proxy
www.feuerwehr.example.de      -> Reverse Proxy
```

## Installation

1. Repository auf den Zielhost übertragen und `config/installation.env.example` kopieren und anpassen. Konfigurationsdateien enthalten keine Passwörter.
2. Gewünschte Anwendungen im Schlüssel `ENABLED_APPS` angeben: `keycloak`, `openwehr`, `matrix`, `onlyoffice`, `grav`.
3. Konfiguration prüfen:

   ```bash
   sudo ./install.sh --config ./config/installation.env.example --dry-run
   ```

4. Installieren (der Installer zeigt die Einstellungen und fragt vor Änderungen nach):

   ```bash
   sudo ./install.sh --config ./config/installation.env.example
   ```

   Alternativ ohne Konfigurationsdatei interaktiv: `sudo ./install.sh`. Der Pfad kann mit `--path /anderer/pfad` überschrieben werden. `--no-start` legt Dateien und Secrets an, startet aber keine Container.

Der Installer kontrolliert Betriebssystem-ID, Root-Rechte, Docker/Compose-Erreichbarkeit, Speicherplatz und bei eigenem Traefik die Hostports. Bei vorhandenen Traefik-Netzwerken prüft er den exakten Netzwerknamen. DNS-Auflösung wird als Warnung angezeigt, wenn `getent` verfügbar ist. Er verändert keine Docker-Netzwerke und überschreibt keine vorhandenen Secret-Dateien. Ein nicht leeres Ziel ohne Stack-`.env` wird abgelehnt.

Für OpenWehr ist alternativ ein vorab ausgecheckter Quellbaum mit `Dockerfile` möglich:

```bash
sudo ./install.sh --config ./config/installation.env.example \
  --openwehr-source /pfad/zum/openwehr-checkout
```

Der automatische Bezug verwendet Commit `8841840042be95ccd6d794067d8dd1f05b30b67c` von `roberteinsle/openwehr`. Der Stack baut daraus lokal das Image `feuerwehr/openwehr:local`; es existiert keine zugesicherte fertige OpenWehr-Registry-Integration.

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
├── openwehr/{source,storage/app}/
├── matrix/data/             # homeserver.yaml, Signaturschlüssel, Medien
├── element/config.json
├── onlyoffice/{logs,data,lib}/
├── grav/config/
├── traefik/acme/acme.json
├── integrations/traefik/dynamic.yml
└── backups/
```

`.env` enthält nur Konfiguration und ist Modus `0600`. Geheimnisse werden einmalig mit `openssl rand` erzeugt und unter `secrets/` gespeichert; erneute Installationsläufe ersetzen sie nicht. Der Keycloak-Bootstrap-Administrator ist `KEYCLOAK_ADMIN_USER`; sein initiales Passwort liegt in `secrets/keycloak_admin_password`. Es wird absichtlich nicht im Terminal ausgegeben. Das leere `secrets/mail_smtp_password` muss bei OpenWehr mit dem SMTP-Passwort befüllt werden.

Compose-Dateisecrets sind auf einem einzelnen Docker-Host schreibgeschützte Datei-Mounts, aber keine verschlüsselten Swarm-Secrets. Docker-Daemon-Administratoren und Host-root können sie lesen. Passwörter, Matrix-Datenbankverbindung und JWT werden beim jeweiligen Containerstart in dessen Prozessumgebung geladen. Schütze daher den Host, Docker-Daemon und Backupzugriff.

Der Installer setzt Besitzerrechte nur für leere Datenverzeichnisse (PostgreSQL 70, Synapse 991, Keycloak/OpenWehr/GRAV 1000). Ändere diese Rechte nicht blind bei bestehenden Daten; prüfe bei Imagewechseln die tatsächliche UID/GID.

## Reverse-Proxy-Modi und TLS

Siehe [`docs/architecture.md`](docs/architecture.md), [`docs/installation.md`](docs/installation.md) und [`docs/reverse-proxy.md`](docs/reverse-proxy.md) für Topologie, Installation, Firewall, DNS, Routing und Betriebsgrenzen.

- **`own`**: eigener Traefik, Ports 80/443, HTTP-zu-HTTPS, ACME HTTP-01 standardmäßig. Die Router entstehen nur für aktivierte Dienste. Dashboard/API wird nicht veröffentlicht. Der Docker-Provider benötigt Zugriff auf `/var/run/docker.sock`; ein `:ro`-Mount macht die Docker-API nicht read-only. Dieser Zugriff ist als weitreichender Hostzugriff zu behandeln.
- **`same-host`**: kein eigener Traefik. Ein existierendes Docker-Netzwerk und dessen Zertifikatsresolver müssen explizit konfiguriert sein. `ENABLE_PROXY_ROUTES=false` erzeugt keine Router. Die optionale Integration verwendet eindeutige Router-Präfixe `fwstack-`.
- **`remote`**: keine Docker-API und keine gemeinsame Netzwerk-ID. Es entstehen eine VPN-IP-gebundene Compose-Portdatei sowie `integrations/traefik/dynamic.yml`. Diese Datei muss der entfernte Betreiber manuell in die bestehende Traefik-Dateikonfiguration übernehmen. Es werden keine externen Server geändert.

DNS-01 für den eigenen Traefik benötigt den Namen eines von Traefik unterstützten Providers und dessen Provider-Variablen. Über `--dns-env-file` wird eine Variablendatei nach `secrets/dns.env` mit Modus `0600` kopiert. Sie wird als Traefik-Umgebung eingebunden und nicht in Git gespeichert. HTTP-01 braucht öffentliche Erreichbarkeit auf Port 80.

## Anwendungen

### PostgreSQL und Redis

PostgreSQL `16.6-alpine` hält `keycloak`, `openwehr` und `synapse` mit getrennten Rollen. Datenbank und Rollen werden nur während der Initialisierung eines leeren Datenverzeichnisses angelegt; ein bestehender Cluster wird nicht automatisch migriert oder mit neuen Passwörtern überschrieben. PostgreSQL ist nicht am Host veröffentlicht.

Redis `7.4.2-alpine` dient OpenWehr als Cache und Queue, nicht als fachliche Datenbank. Es ist intern und nicht persistent: Cache-Inhalte und noch nicht verarbeitete Queue-Jobs können bei Redis-Neustart verloren gehen.

### Keycloak

Keycloak `26.1.4` nutzt PostgreSQL und die externe HTTPS-URL aus `KEYCLOAK_HOST`. Nach dem ersten Start: anmelden, Realm und getrennte Clients für tatsächlich integrierte Anwendungen anlegen und Redirect-URIs eng begrenzen. OpenWehr-OIDC, Matrix-OIDC und GRAV-SSO sind derzeit nicht fertig integriert. Ein erfolgreicher Login darf keine fachlichen Administratorrechte implizieren.

### OpenWehr

Der geprüfte Upstream-Stand verwendet Laravel 12/PHP 8.4, PostgreSQL, Redis für Cache/Queue und einen separaten Queue-Worker; der Scheduler ist im Upstream-Image vorgesehen. Die Upstream-Anmeldung verwendet E-Mail-Magic-Links, nicht OIDC, daher ist SMTP erforderlich. Prüfe die Upstream-Migrationen vor dem ersten Datenbankschema-Update und führe sie nach Sichtung manuell aus:

```bash
sudo docker compose exec openwehr php artisan migrate --force
```

Der upstream bereitgestellte Dockerfile-Basisimage-Tag ist nicht als Digest gepinnt. Aktualisiere ihn kontrolliert und teste den Build. OpenWehr-OIDC und ONLYOFFICE-Callbacks sind nicht implementiert. Uploads, lokale Storage-Dateien und PostgreSQL müssen gemeinsam gesichert werden.

`OPENWEHR_ADMIN_EMAILS` ist eine ausdrückliche Liste initialer Administrator-E-Mail-Adressen. Upstreams `app:ensure-admins` aktiviert bzw. erstellt diese Konten beim Start; halte die Liste deshalb eng und ändere sie nach Bedarf.

### Matrix Synapse und Element

Synapse `v1.125.0` speichert Medien und Konfiguration unter `matrix/data`; die beim ersten Start erzeugte Konfiguration wird auf PostgreSQL gesetzt, Statistiken und offene Registrierung sind deaktiviert. Federation ist standardmäßig aus; `MATRIX_FEDERATION=true` erlaubt Synapse Federation, ersetzt aber keine DNS-, Firewall- oder Well-known-Konfiguration.

`MATRIX_SERVER_NAME` ist die Matrix-Identität und kann von `MATRIX_HOST` abweichen. In diesem Fall müssen die Matrix-`/.well-known`-Dokumente und DNS gezielt eingerichtet werden. Der Stack erzeugt sie nicht. Element `v1.11.92` zeigt auf `MATRIX_HOST`; Synapse-OIDC/Element-OIDC ist nicht fertig eingerichtet und darf nicht als verfügbar angenommen werden.

### ONLYOFFICE und GRAV

ONLYOFFICE Community `8.3.3.1` nutzt die offiziellen persistenten Pfade `/var/log/onlyoffice`, `/var/www/onlyoffice/Data` und `/var/lib/onlyoffice`. JWT ist aktiviert. Eine vollständige Einbindung braucht eine Anwendung, die Dokumente von außen abrufbar macht, JWT prüft und Save-Callbacks verarbeitet; das ist in OpenWehr derzeit nicht implementiert.

GRAV wird mit LinuxServer `version-1.7.48` und persistentem `/config` betrieben. Der Adminbereich ist nicht automatisch durch Keycloak geschützt. GRAV-SSO ist nicht integriert.

## Sicherung, Wiederherstellung, Update und Entfernen

Siehe [`docs/backup-restore.md`](docs/backup-restore.md), [`docs/migration.md`](docs/migration.md) und [`docs/security.md`](docs/security.md).

- Backup: `scripts/backup.sh` stoppt kurz die laufenden App-Container, erstellt konsistente PostgreSQL-Custom-Dumps und sichert Dateien, Konfigurationen und Secrets. Das Backup enthält Geheimnisse und ist Modus `0600`; sichere es zusätzlich verschlüsselt und extern. Redis-Daten sind nicht enthalten.
- Restore: nur auf einem Zielsystem ausführen, dessen Daten überschrieben werden dürfen. Es wird interaktiv bestätigt und nicht automatisch während der Installation ausgelöst.
- Update: `scripts/update.sh` sichert zuerst, zieht die im Compose festgelegten Images und baut OpenWehr neu. Tags werden nicht automatisch geändert; Datenbankmigrationen erfordern weiterhin manuelle Prüfung.
- Deinstallation: `scripts/uninstall.sh` entfernt standardmäßig nur Compose-Container und Stack-Netzwerke. Nur `--delete-data` plus Eingabe des exakten Pfads löscht Backups, Secrets und persistente Daten.

## Fehlerbehebung und bekannte Einschränkungen

- `scripts/validate.sh` prüft Compose-Konfiguration und Dateirechte; `scripts/healthcheck.sh` zeigt Compose-Zustände.
- OpenWehr- oder Synapse-Container starten nach `--no-start` erst, wenn Quellcode bzw. `homeserver.yaml` vorhanden sind. Fehlermeldungen und manuelle Vorbereitung: [`docs/troubleshooting.md`](docs/troubleshooting.md).
- Der Installer prüft keine DNS-Ziel-IP gegen den Host und testet keine Registry-Erreichbarkeit vor dem Start. Er installiert auch keine Betriebssystempakete.
- Matrix-Federation, OIDC, ONLYOFFICE-Dokument-Callbacks, GRAV-SSO, externe SMTP-Erreichbarkeit und Traefik-VPN-Routen benötigen separate Integrationstests.
- Compose-Dateien verwenden feste Versions-Tags; Tags sind nicht zwangsläufig unveränderliche Image-Digests. Prüfe Images vor Produktionsupdates.

## Prüfungen

```bash
tests/run.sh
```

Das Testskript führt Bash-Syntaxprüfung, Python-Syntaxprüfung, ShellCheck (wenn installiert), Installer-Dry-Run-/Eingabetests, Proxy-Konfigurationstests sowie lokale Compose-Modellvalidierung aus. Es benötigt für Compose-Validierung Docker Compose v2, aber keinen laufenden Docker-Daemon. Keine echten Container oder externen Dienste werden gestartet.
