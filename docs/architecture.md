# Architektur

## Laufzeitmodell

Ein fest benanntes Compose-Projekt (`feuerwehr`) läuft auf einem Linux-Host. Es nutzt keine Swarm- oder Overlay-Netzwerke. Compose-Profile aus `COMPOSE_PROFILES` starten nur ausgewählte Anwendungsdienste; PostgreSQL erhält das gemeinsame Profil `data`. Profile werden nicht als Datenlöschmechanismus verwendet.

```text
Internet / externer Traefik
              |
    Proxy-Modus-spezifische Router
              |
        frontend bridge
    ┌─────────┼─────────┐
  Keycloak  Synapse   Webapps
    │         │          │
    └────── backend internal ──────┐
                       PostgreSQL  Redis (WehrPortal)
```

Im Modus `own` hängt der eigene Traefik im Compose-Netzwerk `feuerwehr_frontend`; nur dieser Container veröffentlicht 80/443. Im `same-host`-Modus werden ausgewählte App-Container zusätzlich an das vom Betreiber angegebene externe Docker-Netzwerk angeschlossen. `remote` veröffentlicht ausgewählte Backend-Ports ausschließlich auf einer VPN-IPv4-Adresse; ein entfernter Traefik verwendet eine generierte Dynamic-Konfiguration und benötigt keinen Docker-API-Zugriff.

Alle Anwendungsdaten und Secrets liegen als Host-Bind-Mounts unter `${STACK_ROOT}`. Das Compose-Modell erwartet, dass `STACK_ROOT` mit dem Installationspfad übereinstimmt. PostgreSQL wird per `pg_dump` gesichert, nicht durch Live-Kopieren seines Datenverzeichnisses.

## Dienste und Profile

| Profil | Dienst(e) | Datenbank/Abhängigkeit |
| --- | --- | --- |
| `data` | PostgreSQL 16.6 | Gemeinsamer persistenter Cluster |
| `keycloak` | Keycloak 26.1.4 | Datenbank `keycloak`, Rolle `keycloak` |
| `wehrportal` | WehrPortal Web, Queue-Worker, Redis | DB `wehrportal`, Rolle `wehrportal`; Cache/Queue in Redis |
| `matrix` | Synapse, FluffyChat Web | DB `synapse`, Rolle `synapse` |
| `onlyoffice` | ONLYOFFICE Docs Community | Eingebettete Community-Komponenten |
| `drupal` | Drupal 11.4.11 mit stabilem OpenID Connect | DB `drupal`, Rolle `drupal`, Erweiterung `pg_trgm` |
| `proxy` | Eigener Traefik | Nur im Modus `own` aktiviert |

Der Installer erzeugt `COMPOSE_PROFILES` anhand der Auswahl. Der idempotente PostgreSQL-Initializer erzeugt getrennte App-Datenbanken/Rollen. Bei aktiviertem Drupal wird er durch `scripts/setup-drupal.sh` auch für vorhandene Cluster ausgeführt, damit die neue Drupal-Datenbank und `pg_trgm` verfügbar sind; vorhandene Rollenpasswörter bleiben unverändert. Redis enthält nur Cache-/Queue-Zustand.

## Identität und Anwendung

Bei gemeinsam aktiviertem Drupal und Keycloak richtet der Installer automatisch den gewählten Realm, einen confidential OIDC-Client und Drupals generischen OIDC-Provider ein. Der Callback lautet `/openid-connect/generic`. Die Nutzerzuordnung erfolgt über die externe `sub`-Kennung; gleiche E-Mail-Adressen verknüpfen keine bestehenden Konten. Neue SSO-Nutzer erhalten keine privilegierten Rollen. Ein lokaler Drupal-Notfallzugang bleibt erhalten.

WehrPortal nutzt Laravel-Websessions und E-Mail-Magic-Links. Bei gemeinsamer Auswahl mit Keycloak wird die vorhandene OIDC-Erweiterung automatisch aktiviert und nach den Migrationen über ihre Settings-API konfiguriert. `setup-apps.sh` koordiniert den gemeinsamen Realm und die getrennten Clients `wehrportal`, `drupal` und `synapse`, ohne Drupal vorauszusetzen. WehrPortals Callback ist `/auth/oidc/callback`, sein Client erzwingt PKCE S256; Secrets werden mit dem unveränderten `APP_KEY` verschlüsselt. Bestätigte E-Mail-Adressen dürfen vorhandene aktive Konten beim ersten Login verknüpfen, JIT und SSO-Zwang bleiben initial aus. Private IdP-Ziele sind gesperrt.

Bei gemeinsamer Auswahl von WehrPortal und ONLYOFFICE setzt `setup-wehrportal-office.sh` die Online-Office-Einstellungen über die API des Dateien-Moduls: Browser→öffentliche Office-HTTPS-Adresse, Portal→`http://onlyoffice`, Document Server→öffentliche Portal-HTTPS-Adresse. Das vorhandene JWT-Secret wird geteilt und im Portal mit APP_KEY verschlüsselt. Signierte Downloads und Save-Callbacks verarbeitet die vorhandene Erweiterung; Änderungen werden neue Dateiversionen. Technische Einstellungen werden abgeglichen, Modulaktivierung, Zugriffsrechte sowie Bearbeitungs-/Formatpolitik bleiben unverändert. Keycloak ist für diese Integration nicht erforderlich.

Synapse verwendet bei gemeinsamer Auswahl mit Keycloak den eigenen confidential Client `synapse`, PKCE S256 und den Callback `/_synapse/client/oidc/callback` unter `MATRIX_HOST`. Der Startwrapper generiert fehlende Konfiguration und gleicht PostgreSQL, Basis-URL und den verwalteten Provider ab. Neue SSO-Konten erhalten keine Adminrechte; die Zuordnung erfolgt über `sub`, nicht per automatischem Verknüpfen vorhandener Konten. Offene Registrierung ist gesperrt, lokaler Passwortlogin bleibt erhalten. FluffyChat entdeckt `m.login.sso` über Synapse und benötigt weder OIDC-Client noch Secret. Eine bestehende Keycloak-Browsersitzung kann weitere App-Logins ohne erneute Passworteingabe ermöglichen; App-Sitzungen und Logout bleiben getrennt.

## Persistenz

- PostgreSQL: `${STACK_ROOT}/postgres/data`
- WehrPortal: persistentes Storage unter `${STACK_ROOT}/wehrportal/storage/app`
- Synapse: `${STACK_ROOT}/matrix/data` einschließlich Konfiguration, Schlüsseln und Medien
- ONLYOFFICE: `onlyoffice/{logs,data,lib}`
- Drupal: Inhalte/Konten/Konfiguration in PostgreSQL, öffentliche Dateien unter `drupal/files`, private Dateien und Exporte unter `drupal/private`. Core und Module liegen unveränderlich im gebauten Image.
- Keycloak: optionale Provider/Themes unter `keycloak/`
- ACME: `traefik/acme/acme.json`

Der Redis-Cache, offene Jobs und Containerdateisysteme sind nicht Teil der dauerhaften Anwendungsdaten. Änderungen an Images oder PostgreSQL-Major-Versionen müssen separat geplant werden.
