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
                       PostgreSQL  Redis (OpenWehr)
```

Im Modus `own` hängt der eigene Traefik im Compose-Netzwerk `feuerwehr_frontend`; nur dieser Container veröffentlicht 80/443. Im `same-host`-Modus werden ausgewählte App-Container zusätzlich an das vom Betreiber angegebene externe Docker-Netzwerk angeschlossen. `remote` veröffentlicht ausgewählte Backend-Ports ausschließlich auf einer VPN-IPv4-Adresse; ein entfernter Traefik verwendet eine generierte Dynamic-Konfiguration und benötigt keinen Docker-API-Zugriff.

Alle Anwendungsdaten und Secrets liegen als Host-Bind-Mounts unter `${STACK_ROOT}`. Das Compose-Modell erwartet, dass `STACK_ROOT` mit dem Installationspfad übereinstimmt. PostgreSQL wird per `pg_dump` gesichert, nicht durch Live-Kopieren seines Datenverzeichnisses.

## Dienste und Profile

| Profil | Dienst(e) | Datenbank/Abhängigkeit |
| --- | --- | --- |
| `data` | PostgreSQL 16.6 | Gemeinsamer persistenter Cluster |
| `keycloak` | Keycloak 26.1.4 | Datenbank `keycloak`, Rolle `keycloak` |
| `openwehr` | OpenWehr Web, Queue-Worker, Redis | DB `openwehr`, Rolle `openwehr`; Cache/Queue in Redis |
| `matrix` | Synapse, FluffyChat Web | DB `synapse`, Rolle `synapse` |
| `onlyoffice` | ONLYOFFICE Docs Community | Eingebettete Community-Komponenten |
| `grav` | GRAV CMS | Dateibasierte Inhalte unter `/config` |
| `proxy` | Eigener Traefik | Nur im Modus `own` aktiviert |

Der Installer erzeugt `COMPOSE_PROFILES` anhand der Auswahl. Gemeinsame Datenbankrollen werden nur beim erstmaligen PostgreSQL-Init angelegt; ein vorhandener Cluster wird nicht heimlich verändert. Redis verwendet keine persistente Datenbank und enthält nur Cache-/Queue-Zustand.

## Identität und Anwendung

Keycloak ist als zentraler IdP vorgesehen, aber OIDC-Konfigurationen werden nicht automatisch erzeugt. OpenWehrs Upstream nutzt derzeit Laravel-Websessions und E-Mail-Magic-Links. Matrix-SSO, GRAV-SSO und Dokumentbearbeitungs-Callbacks erfordern separate Integration und Tests. Fachliche OpenWehr-Berechtigungen verbleiben in OpenWehr.

## Persistenz

- PostgreSQL: `${STACK_ROOT}/postgres/data`
- OpenWehr: Quellbaum `${STACK_ROOT}/openwehr/source`, persistentes Laravel-Storage `openwehr/storage/app`
- Synapse: `${STACK_ROOT}/matrix/data` einschließlich Konfiguration, Schlüsseln und Medien
- ONLYOFFICE: `onlyoffice/{logs,data,lib}`
- GRAV: `grav/config`
- Keycloak: optionale Provider/Themes unter `keycloak/`
- ACME: `traefik/acme/acme.json`

Der Redis-Cache, offene Jobs und Containerdateisysteme sind nicht Teil der dauerhaften Anwendungsdaten. Änderungen an Images oder PostgreSQL-Major-Versionen müssen separat geplant werden.
