# Backup und Restore

## Backup

```bash
sudo /srv/apps/feuerwehr/scripts/backup.sh
```

Das Skript stoppt kurz alle laufenden Anwendungscontainer (PostgreSQL, Redis und Traefik bleiben verfügbar), erstellt pro aktivierter App einen PostgreSQL-Custom-Dump und sichert Konfiguration, Secrets und Anwendungsdateien. Danach werden zuvor laufende Anwendungen wieder gestartet. Bei einem Fehler versucht ein Exit-Trap, gestoppte Dienste wieder zu starten.

Der Live-Pfad `postgres/data` wird ausdrücklich nicht kopiert. PostgreSQL-Dumps werden mit `pg_dump` erstellt; Keycloak, WehrPortal, Synapse und Drupal werden bei Bedarf getrennt gesichert. Drupal-Uploads, private Dateien, Builddateien und Secrets sind ebenfalls enthalten. Bei erstmals ausgewähltem, noch nicht provisioniertem Drupal wird der Zustand ausdrücklich als `drupal.not-installed` aufgezeichnet; eine Wiederherstellung dieses Backups führt zu einer frischen Drupal-Installation. Archive erhalten Modus `0600` und enthalten Secrets. Kopiere sie verschlüsselt an einen getrennten Ort.

Redis ist Cache/Queue und wird nicht gesichert. Noch nicht verarbeitete Redis-Jobs können verloren gehen. Prüfe, dass diese Jobs in deiner Installation wiederholbar sind.

## Restore

Erst auf dem Ziel eine leere Stack-Konfiguration mit `install.sh --no-start` anlegen. Kopiere das Backup nach `backups/`, prüfe den Zielpfad und führe aus:

```bash
sudo /srv/apps/feuerwehr/scripts/restore.sh \
  /srv/apps/feuerwehr/backups/feuerwehr-YYYYMMDDTHHMMSSZ.tar.gz
```

Das Skript stoppt den Stack und überschreibt Konfiguration und Anwendungsdateien nach expliziter Eingabe `RESTORE`. Es startet PostgreSQL, synchronisiert Rollenpasswörter aus wiederhergestellten Secret-Dateien und restauriert aktivierte App-Datenbanken. Es kopiert keine PostgreSQL-Datendateien.

Drupal wird aus den wiederhergestellten Build-/Lockdateien gebaut. Drupal-, WehrPortal- und Synapse-Datenbanken werden unter ihrer App-Rolle wiederhergestellt, damit spätere Schema-Updates möglich bleiben; Synapse behält die benötigte C-Kollation. In Swarm bleiben Anwendungen während des Datenbank-Restores auf null Replikaten. Nach dem Start koordiniert `setup-apps.sh` die App-/OIDC-Bereitschaft, `pg_trgm` und die verwalteten Keycloak-Clients.

Für WehrPortal müssen Datenbank, `secrets/wehrportal_app_key` und `secrets/wehrportal_oidc_client_secret` zusammen erhalten bleiben: Der APP_KEY entschlüsselt das gespeicherte Clientsecret; die Identitätszuordnungen liegen in `x_oidc_identities`. Der Worker erhält keinen eigenen Klartext-Secret-Mount. Der Notfallschalter `WEHRPORTAL_OIDC_FORCE_DISABLED` wird mit `.env` wiederhergestellt und vom Setup nicht aufgehoben.

Für Matrix gehören die Synapse-Datenbank mit den SSO-Identitätszuordnungen, `matrix/data` mit Medien und Signaturschlüssel sowie `secrets/synapse_oidc_client_secret` zusammen. Auch Keycloaks Realm/Nutzerkennungen müssen erhalten bleiben: Neue Benutzer mit gleichem Namen ersetzen nicht die bisherige `sub`-Identität. `MATRIX_SERVER_NAME` nach Nutzung nicht ändern; Realmwechsel oder automatische Verknüpfung bestehender Matrix-Konten werden nicht migriert.

Für WehrPortal/ONLYOFFICE müssen Portal-Dateien, Datenbank, `secrets/wehrportal_app_key` und `secrets/onlyoffice_jwt_secret` zusammen erhalten bleiben. Das APP_KEY entschlüsselt die Office-Einstellungen; der Document Server und das Portal müssen dasselbe JWT-Secret verwenden. Nach Restore gleicht `setup-apps.sh` bei gemeinsamer App-Auswahl URLs und Secret erneut ab, ohne Bearbeitungs-/Formatbeschränkungen oder Modulrechte zurückzusetzen.

Prüfe anschließend Container-Health, Keycloak-Login, WehrPortal-Login und Mail, Matrix-Login/Medien, ONLYOFFICE-Verfügbarkeit sowie Drupal-Inhalte und lokalen Notfallzugang. Ein erfolgreicher `pg_restore` ist kein Anwendungstest.

## Backup-Restore-Test

Regelmäßig auf einem separaten Testhost wiederherstellen. Das Skript erzwingt keine Wiederherstellung in einen isolierten Host; ein falscher Zielpfad kann produktive Daten überschreiben. Ein reguläres App-Backup ist nicht für einen PostgreSQL-Major-Wechsel gedacht. `scripts/update.sh` erstellt vor einem erkannten Major-Upgrade zusätzlich einen vollständigen, komprimierten `pg_dumpall`-Cluster-Dump und restauriert diesen in ein neues Cluster. Die Migration stoppt Anwendungen, vergleicht danach Datenbanken und Login-Rollen und lässt das alte Datadir für einen Rückweg erhalten. Ein Downgrade wird abgelehnt. Vor dem Update trotzdem externes Backup und ausreichenden freien Speicher sicherstellen.
