# Fehlerbehebung

## Compose-Konfiguration nicht gültig

```bash
cd /srv/apps/feuerwehr
sudo ./scripts/validate.sh
sudo docker compose --project-directory "$PWD" -f compose.yml config
```

Prüfe, ob `compose.proxy.yml` bzw. `compose.remote.yml` generiert wurde, ob `STACK_ROOT` in `.env` stimmt und ob alle Secret-Dateien existieren. Config-Dateien werden nicht automatisch aus untrusted Shell-Syntax ausgewertet.

## WehrPortal startet nicht

- Prüfe, ob `WEHRPORTAL_IMAGE_TAG` in `.env` auf ein verfügbares Image zeigt und `docker manifest inspect ghcr.io/timux/wehrportal:<Tag>` erfolgreich ist. Standard ist `latest`.
- `APP_KEY`, `DB_PASSWORD`, `MAIL_PASSWORD` werden beim Containerstart aus Secrets geladen.
- PostgreSQL muss gesund sein; WehrPortal führt Migrationen und Scheduler im Produktionscontainer selbst aus.
- Magic-Link-Anmeldung benötigt erreichbares SMTP. Konfiguration in `.env`, Passwort in `secrets/mail_smtp_password`.
- Logs mit `sudo docker compose logs wehrportal wehrportal-worker` prüfen.

## WehrPortal: Online-Office fehlt oder speichert nicht

- `ENABLED_APPS` muss sowohl `wehrportal` als auch `onlyoffice` enthalten. Nach dem Start `sudo ./scripts/setup-apps.sh` ausführen; Keycloak ist hierfür nicht nötig.
- Das WehrPortal-Image muss `Extensions\Dateien\Office\OfficeSettings` und die zugehörigen Migrationen enthalten. In WehrPortal das Dateien-Modul aktivieren und Nutzer-/Dateirechte prüfen; Format- und Bearbeitungsbeschränkungen werden nicht automatisch aufgehoben.
- ONLYOFFICE-Bereitschaft und Logs prüfen; das Setup wartet auf `http://onlyoffice/healthcheck`. Ein erfolgreicher Healthcheck allein bestätigt noch nicht die öffentliche Download-/Rückrufstrecke.
- Browser→Office-HTTPS sowie Document Server→Portal-HTTPS müssen funktionieren, gegebenenfalls über Hairpin-NAT. Private DNS-Zieladressen oder nicht vertrauenswürdige Zertifikate können Downloads verhindern. Keine zusätzliche Proxy-Anmeldung vor `/dateien/office/onlyoffice/` schalten.
- Beide Dienste benötigen dasselbe `secrets/onlyoffice_jwt_secret`; das Portal entschlüsselt seine gespeicherte Kopie mit `wehrportal_app_key`. Nach abgestimmter Rotation Document Server neu erstellen/deployen und Setup erneut ausführen. Secrets nie in Logs veröffentlichen.
- Nach Domainänderungen Portal-Umgebungswerte durch Neuerstellen/Deploy übernehmen und Setup erneut aufrufen. Nur Änderungen in der Portaloberfläche werden beim nächsten Setup durch Stack-Werte ersetzt.

## Synapse startet nicht

Der Startwrapper erzeugt eine fehlende Konfiguration automatisch und setzt bei jedem Start die verwalteten PostgreSQL-/SSO-Werte. Prüfe `MATRIX_SERVER_NAME`, `MATRIX_HOST` und die Federation-Einstellungen vor dem ersten Start.

Bei aktiviertem OIDC müssen Keycloak, der Realm und das öffentliche TLS-Zertifikat erreichbar sein. Während der Erstprovisionierung sind Synapse-Neustarts möglich. Nach DNS-/TLS-Korrektur:

```bash
sudo docker compose logs --tail 80 synapse
sudo docker compose restart synapse
sudo ./scripts/setup-apps.sh
```

Bei geänderten Umgebungswerten Synapse neu erstellen/deployen statt nur neu starten; nutze den Compose-Befehl einschließlich Proxy-Override aus `docs/installation.md`. PostgreSQL-Zugangsdaten liegen in `matrix/data/homeserver.yaml` als geschützte Konfiguration; prüfe Modus `0600`. Zum sicheren Rotieren DB-Rolle und Synapse-Konfiguration abgestimmt ändern. Das OIDC-Secret liegt separat in `secrets/synapse_oidc_client_secret`. Ein bereits belegter Matrix-Benutzername wird nicht automatisch mit Keycloak verbunden; ein SSO-Konto kann deshalb einen Ziffernsuffix erhalten.

## Keine Proxy-Route oder kein Zertifikat

- Prüfe A/AAAA-Einträge und dass sie zum richtigen Host/VPN zeigen.
- Im `own`-Modus müssen 80/443 ankommen und andere Dienste dürfen diese Ports nicht belegen.
- Im `same-host`-Modus müssen Stack und vorhandener Traefik am exakt konfigurierten Netzwerk hängen; Resolvername prüfen.
- Im `remote`-Modus muss die dynamic.yml manuell beim entfernten Traefik geladen sein. VPN-Routen, Hostport-Bindung und Firewall prüfen.
- Traefik-Logs enthalten ACME-Fehler: `sudo docker compose logs traefik`.

## Rechte / Datenpfad

Der Installer chown't nur leere Verzeichnisse. Für bestehende Daten zuerst Container-UID/GID der gewählten Image-Version prüfen. Nicht `chmod -R 777` verwenden. PostgreSQL-Daten niemals löschen, um einen Berechtigungsfehler zu umgehen.
