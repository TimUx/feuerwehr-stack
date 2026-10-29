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

Der normale Installer erzeugt bei aktivem Matrix-Profil eine Synapse-Konfiguration, setzt PostgreSQL und startet anschließend den Stack. Bei `--no-start` führt ein Administrator die Schritte aus `docs/troubleshooting.md` aus und startet mit den erzeugten Compose-Dateien.

Bei ausgewähltem WehrPortal prüft der Installer standardmäßig `ghcr.io/timux/wehrportal:latest` vor Änderungen am Installationspfad und speichert `WEHRPORTAL_IMAGE_TAG=latest` in `.env`. Bei bestehenden Installationen den alten festen Wert in `.env` einmalig auf `latest` ändern oder den Installer mit der aktualisierten Konfiguration erneut ausführen. Ein expliziter Release-Tag bleibt möglich und wird über GitHub und GHCR verifiziert. PostgreSQL ist Pflicht. Der WehrPortal-Produktionscontainer führt Datenbankmigrationen und Scheduler beim Start selbst aus; der separate Worker startet ohne parallele Migrationen. Die initialen Admin-Adressen werden über `WEHRPORTAL_ADMIN_EMAILS` konfiguriert.

`scripts/update.sh` migriert PostgreSQL bei einem Major-Versionswechsel automatisch per logischem Dump/Restore. Vor der Migration entsteht zusätzlich zum regulären Backup ein vollständiger Cluster-Dump; die bisherige Datendatei bleibt nach erfolgreichem Wechsel unter `postgres/data.pg<Major>-<Zeitstempel>` erhalten. Plane Downtime und mindestens zusätzlichen Speicherplatz für ein weiteres vollständiges Cluster und das komprimierte Backup ein. Downgrades werden nicht automatisch unterstützt.

WehrPortal unterstützt keine Übernahme bestehender OpenWehr-Daten. Der Installer lehnt einen alten Stack-Pfad oder ein bestehendes PostgreSQL-Datenverzeichnis ab. Installiere WehrPortal in einem separaten leeren Pfad und bewahre alte Installation, Backups und Secrets unverändert auf.

Keycloak-Bootstrap-Zugangsdaten findest du nach Installation geschützt in `secrets/`. Das Passwort wird nicht angezeigt. Nach der ersten Anmeldung Realm, getrennte Clients, Redirect-URIs und Rollen manuell konfigurieren.

## Manuelle Compose-Kommandos

Für den Betrieb sind die Skripte vorzuziehen. Bei direkten Compose-Aufrufen müssen die generierten Override-Dateien angegeben werden:

```bash
cd /srv/apps/feuerwehr
files=(-f compose.yml)
[[ ! -f compose.proxy.yml ]] || files+=(-f compose.proxy.yml)
[[ ! -f compose.remote.yml ]] || files+=(-f compose.remote.yml)
sudo docker compose --project-directory "$PWD" "${files[@]}" up -d
```
