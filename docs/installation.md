# Installation und Erstkonfiguration

## Betriebssystem und Host

Der Installer akzeptiert Debian und Ubuntu sowie Docker Engine, Compose-Plugin v2, OpenSSL, `ss`, `df` und Root. Er installiert keine Pakete und aktualisiert keine Systemdienste. Docker muss erreichbar sein. Bei `own` müssen TCP 80 und 443 frei sein; bei `same-host` muss das konfigurierte externe Netz bereits bestehen.

## Einstellungen

Kopiere `config/installation.env.example` und setze mindestens echte Domainnamen, ACME-E-Mail, SMTP-Server/-Absender sowie die gewünschten `ENABLED_APPS`. Werte werden zeilenweise als `KEY=VALUE` gelesen, nicht als Shell-Code ausgeführt. Unbekannte Schlüssel werden ignoriert. Bestehende `.env`-Werte sind bei erneuten Installationen die Quelle der Wahrheit.

Secrets werden separat erstellt. Gib keine Passwörter in die Konfigurationsdatei ein. Für DNS-01 wird eine zusätzliche Provider-Env-Datei benötigt; sie wird als `secrets/dns.env` geschützt abgelegt.

## Installer und Dry-Run

```bash
sudo ./install.sh --help
sudo ./install.sh --config ./config/installation.env --dry-run
sudo ./install.sh --config ./config/installation.env --path /srv/apps/feuerwehr
```

`--dry-run` führt keine Dateierstellung, Image-Pulls oder Containerstarts aus. Er prüft Domainsyntax, Reverse-Proxy-Auswahl, Remote-IP/Ports und bei eigenem Traefik belegte Ports. Docker-Netzwerk- und Hostchecks werden bei einer regulären Installation durchgeführt. `--no-start` bereitet die Stackdateien vor und lässt die eigentliche Diensteausführung aus.

Vor der ersten Änderung zeigt der Installer Pfad, aktive Dienste, Proxy-Modus und Matrix-Federation und verlangt Bestätigung. `--yes` überspringt nur diese Bestätigung; es deaktiviert keine Validierungen.

## Erststart

Der normale Installer erzeugt bei aktivem Matrix-Profil eine Synapse-Konfiguration, setzt PostgreSQL und startet anschließend den Stack. Bei `--no-start` führt ein Administrator die Schritte aus `docs/troubleshooting.md` aus und startet mit den erzeugten Compose-Dateien.

Bei ausgewähltem OpenWehr prüfe vor Start den Quellcommit, den lokalen Produktionsbuild und die SMTP-Parameter. Der Stack führt Datenbankmigrationen nicht automatisch aus (`AUTORUN_ENABLED=false`). Prüfe Migrationen und führe sie anschließend gezielt mit `php artisan migrate --force` aus. Die initialen Admin-Adressen werden über `OPENWEHR_ADMIN_EMAILS` explizit konfiguriert.

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
