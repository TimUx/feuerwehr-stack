# Sicherheitsmodell und Hardening

## Implementierte Baselines

- Keine Hostports für PostgreSQL, Redis oder Anwendungscontainer in den Modi `own`/`same-host`.
- Reverse-Proxy-Router nur für ausgewählte Dienste; eigener Traefik nutzt `exposedByDefault=false`.
- PostgreSQL-Apps haben getrennte Rollen und Datenbanken.
- Secrets entstehen mit OpenSSL-CSPRNG, werden nicht ausgegeben und bei erneuter Installation nicht ersetzt.
- `.env`, Secret-Dateien und ACME-Datei erhalten restriktive Host-Dateirechte.
- Nicht leere Installationspfade ohne Stack-Marker werden abgelehnt.
- Container haben Restart-Policies und Healthchecks, soweit das jeweilige Image bzw. der Dienst sie unterstützt.
- Drupal-Basisimage ist per Version und Digest fixiert; seine PHP-Abhängigkeiten sind gelockt. Andere Dienste verwenden teils bewegliche `latest`-Tags.
- Kein `privileged`, keine Docker-API-Veröffentlichung; Backend-Netzwerk ist als Compose-intern definiert.

## Grenzen und Betriebsmaßnahmen

Docker Compose-Dateisecrets sind einfache Host-Datei-Mounts und nicht wie Swarm-Secrets im Ruhezustand verschlüsselt. Der Docker-Daemon sowie root können Hostdateien und Containerumgebungen lesen. Sichere den Host, SSH-Zugang, Docker-Gruppe, Backups und Dateisystem.

Traefik mit Docker-Provider benötigt `/var/run/docker.sock`. `:ro` beschränkt Dateischreibzugriffe, nicht API-Funktionen; behandle den Provider als privilegierten Hostzugriff. Eine Docker-API darf niemals öffentlich erreichbar sein. Ein Socket-Proxy ist nicht Teil dieses Projekts.

Drupals OIDC-Secret wird per `settings.php` aus der Secret-Datei gelesen und nicht in Konfigurationsexporte geschrieben. Neue SSO-Nutzer erhalten keine privilegierten Rollen; die automatische Verknüpfung bestehender Konten anhand gleicher E-Mail-Adressen ist deaktiviert. Der lokale Notfalladministrator bleibt unabhängig von Keycloak verfügbar. Die Keycloak-Adminzugangsdaten werden nur beim expliziten Bootstrap/Setup zum Abgleich des verwalteten Clients verwendet; sie werden nicht an Drupal weitergegeben.

WehrPortals eigener OIDC-Client verwendet Code Flow mit verpflichtendem PKCE S256 und exaktem Callback. Sein Secret wird über die Plugin-API mit APP_KEY verschlüsselt gespeichert; der Klartext-Mount liegt nur im Webcontainer. Keycloak-Adminzugangsdaten bleiben außerhalb des Portals. Anders als bei Drupal ist das initiale Verknüpfen vorhandener aktiver Konten über eine bestätigte E-Mail erlaubt. JIT, SSO-Zwang und Rollenmapping sind nicht automatisch aktiv. Private IdP-Ziele bleiben durch `SafeUrl` gesperrt. Der lokale Mail-Link-Notfallzugang braucht SMTP; `WEHRPORTAL_OIDC_FORCE_DISABLED` bleibt auch bei erneutem Setup wirksam.

Synapses eigener OIDC-Client verwendet Code Flow mit PKCE S256 und exaktem Callback unter `MATRIX_HOST`. Das Clientsecret bleibt als Dateiverweis außerhalb der `homeserver.yaml`; Keycloak-Adminzugangsdaten werden nicht in Synapse gemountet. JIT erstellt nur normale Matrix-Konten; vorhandene Konten werden nicht automatisch verknüpft, Rollen nicht übernommen. Offene Registrierung bleibt aus. Nur die eigene FluffyChat-HTTPS-Origin mit abschließendem `/` wird für die direkte Rückgabe einmaliger Matrix-Login-Tokens freigegeben; keine Redirect-Wildcards. Lokale Passwortkonten können unabhängig von Keycloak weiter genutzt werden, ein lokaler Admin wird nicht automatisch eingerichtet.

WehrPortal und ONLYOFFICE teilen `secrets/onlyoffice_jwt_secret`. Der Portal-Webcontainer erhält einen schreibgeschützten Mount; Speicherung erfolgt über die Dateien-API mit APP_KEY verschlüsselt, der Worker bekommt keinen Klartext-Mount. Signierte Editor-Konfigurationen, Downloads und Save-Callbacks werden vom Dateien-Modul geprüft; bestehende Rechte und Bearbeitungsbeschränkungen bleiben maßgeblich. Technische Office-Einstellungen sind Stack-verwaltet. Der produktive Document Server erhält keine pauschale Freigabe privater Downloadziele und keine deaktivierte TLS-Prüfung. Das interne Portal→Office-HTTP läuft ausschließlich im Docker-Netz; öffentliche Browser- und Rückrufadressen verwenden HTTPS.

Schütze `.env`, `secrets/`, Matrix-Signaturschlüssel, PostgreSQL-Dateien und Backups durch Host-Backups, Zugriffskontrolle und Verschlüsselung außerhalb des Hosts. Rotationen erfordern abgestimmte Änderungen der betroffenen Datenbankrollen/Anwendungen; bestehende PostgreSQL-Rollen werden bei einer Reinstallation nicht stillschweigend geändert.

Der Installer prüft nur leere Datenverzeichnisse auf UID/GID und setzt dann erwartete Besitzer. Ändere Owner/ACL bestehender Dateien nicht automatisiert. Prüfe die tatsächlichen Container-UIDs beim Imagewechsel. Verwende Host-Firewall-Regeln nach `docs/reverse-proxy.md`; Docker-Portpublishing kann UFW-Regeln umgehen.

## Vor produktivem Einsatz

1. Passe die unterstützten Images/Tags an den genehmigten Patchstand an und prüfe deren Herkunft/Digests.
2. Prüfe DNS, Zertifikate, SMTP, WebSockets, große Uploads und externe Erreichbarkeit.
3. Aktiviere weder offene Matrix-Registrierung noch Adminclients ohne Bedarf.
4. Lege Keycloak-Clients mit engen Redirect-URIs an; gib niemandem implizit App-Adminrechte.
5. Erstelle und teste ein verschlüsseltes Backup sowie Restore auf einem getrennten Testhost.
6. Erstelle eine Firewallregel nur für tatsächlich benötigte Proxy-/VPN-Ports.
