# Sicherheitsmodell und Hardening

## Implementierte Baselines

- Keine Hostports für PostgreSQL, Redis oder Anwendungscontainer in den Modi `own`/`same-host`.
- Reverse-Proxy-Router nur für ausgewählte Dienste; eigener Traefik nutzt `exposedByDefault=false`.
- PostgreSQL-Apps haben getrennte Rollen und Datenbanken.
- Secrets entstehen mit OpenSSL-CSPRNG, werden nicht ausgegeben und bei erneuter Installation nicht ersetzt.
- `.env`, Secret-Dateien und ACME-Datei erhalten restriktive Host-Dateirechte.
- Nicht leere Installationspfade ohne Stack-Marker werden abgelehnt.
- Container haben Restart-Policies und Healthchecks, soweit das jeweilige Image bzw. der Dienst sie unterstützt.
- Keine `latest`-Tags. Tags sind explizit, können aber vom Registry-Betreiber verschoben werden.
- Kein `privileged`, keine Docker-API-Veröffentlichung; Backend-Netzwerk ist als Compose-intern definiert.

## Grenzen und Betriebsmaßnahmen

Docker Compose-Dateisecrets sind einfache Host-Datei-Mounts und nicht wie Swarm-Secrets im Ruhezustand verschlüsselt. Der Docker-Daemon sowie root können Hostdateien und Containerumgebungen lesen. Sichere den Host, SSH-Zugang, Docker-Gruppe, Backups und Dateisystem.

Traefik mit Docker-Provider benötigt `/var/run/docker.sock`. `:ro` beschränkt Dateischreibzugriffe, nicht API-Funktionen; behandle den Provider als privilegierten Hostzugriff. Eine Docker-API darf niemals öffentlich erreichbar sein. Ein Socket-Proxy ist nicht Teil dieses Projekts.

Schütze `.env`, `secrets/`, Matrix-Signaturschlüssel, PostgreSQL-Dateien und Backups durch Host-Backups, Zugriffskontrolle und Verschlüsselung außerhalb des Hosts. Rotationen erfordern abgestimmte Änderungen der betroffenen Datenbankrollen/Anwendungen; bestehende PostgreSQL-Rollen werden bei einer Reinstallation nicht stillschweigend geändert.

Der Installer prüft nur leere Datenverzeichnisse auf UID/GID und setzt dann erwartete Besitzer. Ändere Owner/ACL bestehender Dateien nicht automatisiert. Prüfe die tatsächlichen Container-UIDs beim Imagewechsel. Verwende Host-Firewall-Regeln nach `docs/reverse-proxy.md`; Docker-Portpublishing kann UFW-Regeln umgehen.

## Vor produktivem Einsatz

1. Passe die unterstützten Images/Tags an den genehmigten Patchstand an und prüfe deren Herkunft/Digests.
2. Prüfe DNS, Zertifikate, SMTP, WebSockets, große Uploads und externe Erreichbarkeit.
3. Aktiviere weder offene Matrix-Registrierung noch Adminclients ohne Bedarf.
4. Lege Keycloak-Clients mit engen Redirect-URIs an; gib niemandem implizit App-Adminrechte.
5. Erstelle und teste ein verschlüsseltes Backup sowie Restore auf einem getrennten Testhost.
6. Erstelle eine Firewallregel nur für tatsächlich benötigte Proxy-/VPN-Ports.
