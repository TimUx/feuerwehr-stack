# Reverse Proxy, Domains und TLS

`PROXY_MODE` ist genau einer der Werte `own`, `same-host` oder `remote`. Domainwerte müssen gültige DNS-Hostnamen sein. Nur aktivierte Anwendungen erhalten Router oder Remote-Portbindungen.

| Dienst | Hostname-Schlüssel | Interner Backend-Port |
| --- | --- | ---: |
| Keycloak | `KEYCLOAK_HOST` | 8080 |
| WehrPortal | `WEHRPORTAL_HOST` | 8080 |
| Synapse Client-Server/Federation | `MATRIX_HOST` | 8008 |
| FluffyChat Web | `FLUFFYCHAT_HOST` | 8080 |
| ONLYOFFICE | `ONLYOFFICE_HOST` | 80 |
| GRAV | `GRAV_HOST` | 80 |

PostgreSQL und Redis besitzen keine Host-Portfreigabe. In den Modi `same-host` und `remote` gibt es keine automatische Hostportfreigabe für die internen Datenbanken.

## Eigener Traefik (`own`)

Der Installer startet Traefik im Profil `proxy`, veröffentlicht ausschließlich 80/443 und konfiguriert HTTP-zu-HTTPS sowie ACME HTTP-01. Firewall: TCP 80/443 eingehend zum Host; Domains müssen auf diesen Host zeigen. Ports werden vorab geprüft. Führe nicht gleichzeitig einen zweiten Proxy auf denselben Ports.

Für DNS-01:

```bash
sudo ./install.sh --config installation.env \
  --dns-env-file /root/provider.env
```

`ACME_DNS_PROVIDER` muss der Traefik-Providerkennung entsprechen; `provider.env` muss die für diesen Provider erwarteten Variablen enthalten. Die Datei landet unter `secrets/dns.env` und wird als Prozessumgebung an Traefik übergeben. Eine providerübergreifende Prüfung des Inhalts findet nicht statt. ACME-Test, Domaininhaberschaft und Zertifikatsausstellung wurden nicht durchgeführt.

Der Docker-Provider hat `exposedByDefault=false`; pro aktivierter Anwendung wird ein Router explizit gesetzt. Das Dashboard ist deaktiviert und nicht veröffentlicht. Der Docker-Socket-Mount ist trotz `:ro` kein sicherer Ersatz für einen Socket-Proxy: API-Zugriff kann Host-Kontrolle erlauben. Beschränke Zugriff auf den Stack-Host und erwäge einen separat gehärteten Docker-Socket-Proxy.

## Existierender Traefik über gemeinsames Docker-Netzwerk (`same-host`)

Der Installer verlangt den expliziten Netzwerknamen `TRAEFIK_NETWORK` und prüft, dass es bereits existiert. Das Netzwerk wird nicht erstellt oder verändert. Es muss ein benutzerdefiniertes Docker-Netzwerk sein, an das der vorhandene Traefik bereits angeschlossen ist. Das kann auch ein attachable Overlay-Netzwerk sein, über das ein Traefik auf einem anderen Host die Container erreicht. Die Labels setzen sowohl `traefik.docker.network` als auch `traefik.swarm.network` auf diesen Netzwerknamen und `X-Forwarded-Proto: https` über eine eigene Middleware je Dienst. Mit `TRAEFIK_MIDDLEWARES` (kommagetrennt, z. B. `frontend-security-chain@file`) werden vorhandene Middlewares des Traefik vor diese Middleware geschaltet. Router und Services tragen den Präfix `fwstack-` (z. B. `fwstack-onlyoffice`), damit sie nicht mit gleichnamigen Services anderer Stacks am selben Traefik kollidieren. `scripts/update.sh` erzeugt Labels und Router aus der `.env` neu. Nur mit `ENABLE_PROXY_ROUTES=true` werden Labels und Router erzeugt. `TRAEFIK_CERT_RESOLVER` muss auf einen bereits konfigurierten Resolver zeigen.

Die Router-Namen sind mit `fwstack-` präfixiert. Prüfe `compose.proxy.yml` vor dem Start trotzdem gegen deine vorhandene Traefik-Konfiguration. Router werden nicht automatisch in die bestehende Traefik-Instanz übernommen, wenn die Route deaktiviert ist.

## Entfernt betriebener Traefik (`remote`)

Dieser Modus benötigt weder Docker-API noch Netzwerk-ID des entfernten Proxys. Der Installer erstellt:

- `compose.remote.yml`: nur aktivierte Anwendungsports werden an `VPN_BACKEND_IP` gebunden.
- `integrations/traefik/dynamic.yml`: eindeutige Router und HTTP-Backends für den entfernten Dateiprovider.

Übertrage die Dynamic-Konfiguration manuell auf den Traefik-Host. Die Datei ändert keine bestehende Infrastruktur. Stelle auf dem Backend-Host per Firewall sicher, dass diese Ports ausschließlich aus dem VPN bzw. vom Traefik-Host erreichbar sind. Der Stack-Host braucht eine VPN-Adresse, die aus dem Proxy-Netz erreichbar ist. Eingehend öffentlich bleiben nur Ports, die der entfernte Proxy benötigt.

Die dynamischen Backends verwenden HTTP innerhalb des VPN. TLS endet am entfernten Traefik; `X-Forwarded-Proto: https` wird gesetzt. Traefik unterstützt WebSockets ohne zusätzliche Upgrade-Regel. Es ist kein Request-Buffering konfiguriert, damit große Uploads nicht vollständig zwischengespeichert werden; Response-Header-Timeout ist 300 Sekunden. Prüfe längere Uploads und anwendungsspezifische Timeouts produktiv.

Remote IPv6-Adressen werden vom Installer aktuell nicht unterstützt. Hostports können in der Installationskonfiguration angepasst werden und müssen eindeutig sein.

## Matrix-Domainmodell

`MATRIX_HOST` ist die HTTPS-Adresse für Client-Server-API und wird als FluffyChats Standard-Homeserver konfiguriert. `MATRIX_SERVER_NAME` identifiziert Matrix-Konten/Federation. Stimmen sie nicht überein, müssen `/.well-known/matrix/client` und `/.well-known/matrix/server` zur passenden API bzw. Federation-Adresse zeigen. Diese Well-known-Dateien werden nicht generiert. Federation ist standardmäßig deaktiviert und benötigt zusätzliche DNS-/Firewall-Prüfung.

## Docker-Swarm-Modus

Liest ein Traefik (auch auf einem anderen Host) nur den Swarm-Provider, ignoriert er Labels normaler Container. Dann im Installer `DEPLOY_MODE=swarm` wählen (nur mit `PROXY_MODE=same-host`):

- Voraussetzungen: Swarm-Manager-Knoten, `python3`, `TRAEFIK_NETWORK` ist ein Overlay-Netz mit Scope `swarm`.
- `scripts/generate-swarm-stack.py` erzeugt aus `compose.yml` und `compose.proxy.yml` die Datei `stack.swarm.yml` (Labels unter `deploy.labels`, CPU/RAM als `deploy.resources.limits`, Secrets mit Hash-Suffix, Overlay-Netze). Deployment: `docker stack deploy -c stack.swarm.yml feuerwehr`; `update.sh` macht das automatisch.
- Alle Dienste sind per Platzierungsregel an den Installationsknoten gebunden (Bind-Mounts und Secrets liegen lokal). Es gibt kein `depends_on`; Neustarts übernimmt die Restart-Policy.
- `backup.sh`, `restore.sh`, `healthcheck.sh`, `update.sh`, `uninstall.sh` erkennen den Modus über `DEPLOY_MODE` in `.env`.
- Moduswechsel: zuvor den anderen Modus beenden (`docker compose down` bzw. `docker stack rm feuerwehr`).
