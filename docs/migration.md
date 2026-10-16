# Migration auf einen anderen Host

1. Auf dem Quellhost `scripts/backup.sh` ausführen und das Archiv verschlüsselt übertragen.
2. Auf dem Zielhost eine unterstützte Linux-Version, Docker Engine und Compose v2 installieren. Firewall-/VPN-Regeln und DNS vorbereiten.
3. Repository auf dem Ziel bereitstellen und mit der gewünschten Zielpfadwahl `sudo ./install.sh --no-start` ausführen. Aktivierte Profile müssen zu den gesicherten Daten passen.
4. Backup in den Installationspfad kopieren und mit `scripts/restore.sh ARCHIV` wiederherstellen.
5. Beim Remote-Traefik-Modus `integrations/traefik/dynamic.yml` manuell auf den Proxy-Host übertragen und dessen Dateiprovider neu laden. Für same-host müssen Docker-Netzwerk und Resolver bereits existieren.
6. DNS bei Bedarf ändern. Sobald TLS-/DNS-TTLs abgelaufen sind, Anwendungen und Federation von außen testen.

Restore setzt `STACK_ROOT` in `.env` auf den tatsächlich verwendeten Zielpfad. Wenn sich die VPN-IP ändert, aktualisiere `VPN_BACKEND_IP` und generiere die Remote-Konfiguration erneut, bevor du sie auf den Traefik-Host überträgst.

Die Compose-Netzwerke werden am Ziel neu angelegt; es wird keine Netzwerk-ID migriert. Datenbankdateien werden nicht hostweise kopiert. Ein Hostname, eine IP oder Docker-Netzwerk-ID muss nicht identisch bleiben. Eine Änderung von `MATRIX_SERVER_NAME` nach produktiver Nutzung ist dagegen keine normale Migration und kann Matrix-Identitäten/Federation brechen.
