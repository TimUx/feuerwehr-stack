# Fehlerbehebung

## Compose-Konfiguration nicht gültig

```bash
cd /srv/apps/feuerwehr
sudo ./scripts/validate.sh
sudo docker compose --project-directory "$PWD" -f compose.yml config
```

Prüfe, ob `compose.proxy.yml` bzw. `compose.remote.yml` generiert wurde, ob `STACK_ROOT` in `.env` stimmt und ob alle Secret-Dateien existieren. Config-Dateien werden nicht automatisch aus untrusted Shell-Syntax ausgewertet.

## WehrPortal startet nicht

- Prüfe, ob `.env` einen veröffentlichten festen `WEHRPORTAL_IMAGE_TAG` enthält und `docker manifest inspect ghcr.io/timux/wehrportal:<Tag>` erfolgreich ist.
- `APP_KEY`, `DB_PASSWORD`, `MAIL_PASSWORD` werden beim Containerstart aus Secrets geladen.
- PostgreSQL muss gesund sein; WehrPortal führt Migrationen und Scheduler im Produktionscontainer selbst aus.
- Magic-Link-Anmeldung benötigt erreichbares SMTP. Konfiguration in `.env`, Passwort in `secrets/mail_smtp_password`.
- Logs mit `sudo docker compose logs wehrportal wehrportal-worker` prüfen.

## Synapse startet nicht

Bei `--no-start` generiere die Konfiguration nach dem Prüfen der `MATRIX_SERVER_NAME`- und Federation-Einstellungen:

```bash
sudo docker compose run --rm --no-deps synapse generate
sudo docker compose run --rm --no-deps --user 0:0 --entrypoint python synapse /stack/configure_synapse.py
```

Eine vorhandene `matrix/data/homeserver.yaml` wird nicht überschrieben. PostgreSQL-Zugangsdaten liegen dort als geschützte Konfiguration; prüfe Modus `0600`. Zum sicheren Rotieren DB-Rolle und Synapse-Konfiguration abgestimmt ändern. Starte den Stack anschließend mit dem Compose-Befehl aus `docs/installation.md`, damit der passende Proxy-Override verwendet wird.

## Keine Proxy-Route oder kein Zertifikat

- Prüfe A/AAAA-Einträge und dass sie zum richtigen Host/VPN zeigen.
- Im `own`-Modus müssen 80/443 ankommen und andere Dienste dürfen diese Ports nicht belegen.
- Im `same-host`-Modus müssen Stack und vorhandener Traefik am exakt konfigurierten Netzwerk hängen; Resolvername prüfen.
- Im `remote`-Modus muss die dynamic.yml manuell beim entfernten Traefik geladen sein. VPN-Routen, Hostport-Bindung und Firewall prüfen.
- Traefik-Logs enthalten ACME-Fehler: `sudo docker compose logs traefik`.

## Rechte / Datenpfad

Der Installer chown't nur leere Verzeichnisse. Für bestehende Daten zuerst Container-UID/GID der gewählten Image-Version prüfen. Nicht `chmod -R 777` verwenden. PostgreSQL-Daten niemals löschen, um einen Berechtigungsfehler zu umgehen.
