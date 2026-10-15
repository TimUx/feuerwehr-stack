# Backup und Restore

## Backup

```bash
sudo /srv/apps/feuerwehr/scripts/backup.sh
```

Das Skript stoppt kurz alle laufenden Anwendungscontainer (PostgreSQL, Redis und Traefik bleiben verfügbar), erstellt pro aktivierter App einen PostgreSQL-Custom-Dump und sichert Konfiguration, Secrets und Anwendungsdateien. Danach werden zuvor laufende Anwendungen wieder gestartet. Bei einem Fehler versucht ein Exit-Trap, gestoppte Dienste wieder zu starten.

Der Live-Pfad `postgres/data` wird ausdrücklich nicht kopiert. PostgreSQL-Dumps werden mit `pg_dump` erstellt; Keycloak, OpenWehr und Synapse werden bei Bedarf getrennt gesichert. Archive werden mit Modus `0600` unter `backups/` abgelegt und enthalten Secrets. Kopiere sie anschließend verschlüsselt an einen getrennten Ort.

Redis ist Cache/Queue und wird nicht gesichert. Noch nicht verarbeitete Redis-Jobs können verloren gehen. Prüfe, dass diese Jobs in deiner Installation wiederholbar sind.

## Restore

Erst auf dem Ziel eine leere Stack-Konfiguration mit `install.sh --no-start` anlegen. Kopiere das Backup nach `backups/`, prüfe den Zielpfad und führe aus:

```bash
sudo /srv/apps/feuerwehr/scripts/restore.sh \
  /srv/apps/feuerwehr/backups/feuerwehr-YYYYMMDDTHHMMSSZ.tar.gz
```

Das Skript stoppt den Stack und überschreibt Konfiguration und Anwendungsdateien nach expliziter Eingabe `RESTORE`. Es startet PostgreSQL, synchronisiert Rollenpasswörter aus wiederhergestellten Secret-Dateien und restauriert aktivierte App-Datenbanken. Es kopiert keine PostgreSQL-Datendateien.

Prüfe anschließend Container-Health, Keycloak-Login, OpenWehr-Migrationen und Mail, Matrix-Login/Medien, ONLYOFFICE-Verfügbarkeit sowie GRAV-Inhalte. Ein erfolgreicher `pg_restore` ist kein Anwendungstest.

## Backup-Restore-Test

Regelmäßig auf einem separaten Testhost wiederherstellen. Das Skript erzwingt keine Wiederherstellung in einen isolierten Host; ein falscher Zielpfad kann produktive Daten überschreiben. Eine Wiederherstellung über unterschiedliche PostgreSQL-Major-Versionen ist nicht zugesichert; zuerst gleiche Image-Version verwenden und Major-Upgrades separat planen.
