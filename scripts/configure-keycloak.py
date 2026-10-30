#!/usr/bin/env python3
"""Provision selected stack-owned OIDC clients over Keycloak's HTTPS Admin API."""
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


class ProvisionError(Exception):
    pass


class Keycloak:
    def __init__(self, base_url):
        self.base_url = base_url
        self.token = None

    def request(self, method, path, data=None, form=False):
        headers = {}
        body = None
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if data is not None:
            if form:
                body = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=body, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=10) as response:
            raw = response.read()
            return json.loads(raw) if raw else None


def read_secret(root, name):
    path = root / "secrets" / name
    if path.is_symlink() or not path.is_file():
        raise ProvisionError(f"Missing or unsafe secret file: {name}")
    value = path.read_text().strip()
    if not value:
        raise ProvisionError(f"Empty secret file: {name}")
    return value


def provision(root):
    values = {}
    for line in (root / ".env").read_text().splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    applications = []
    for app, host, callback in (
        ("drupal", "DRUPAL_HOST", "/openid-connect/generic"),
        ("wehrportal", "WEHRPORTAL_HOST", "/auth/oidc/callback"),
        ("synapse", "MATRIX_HOST", "/_synapse/client/oidc/callback"),
    ):
        flag = "MATRIX_OIDC_ENABLED" if app == "synapse" else app.upper() + "_OIDC_ENABLED"
        if values.get(flag) == "true":
            applications.append((app, host, callback))
    if not applications:
        print("No application selected for Keycloak OIDC provisioning.")
        return
    realm = values["KEYCLOAK_REALM"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]{0,63}", realm) or realm == "master":
        raise ProvisionError("KEYCLOAK_REALM must be a dedicated realm, not master.")
    api = Keycloak("https://" + values["KEYCLOAK_HOST"])
    deadline = time.monotonic() + 180
    while True:
        try:
            api.request("GET", "/realms/master/.well-known/openid-configuration")
            break
        except (urllib.error.URLError, TimeoutError):
            if time.monotonic() >= deadline:
                raise ProvisionError("Keycloak HTTPS is not reachable. Check DNS, TLS and proxy routes, "
                                     "then rerun scripts/setup-apps.sh.")
            time.sleep(3)
    auth = api.request("POST", "/realms/master/protocol/openid-connect/token", {
        "client_id": "admin-cli", "grant_type": "password",
        "username": values["KEYCLOAK_ADMIN_USER"],
        "password": read_secret(root, "keycloak_admin_password"),
    }, form=True)
    api.token = auth["access_token"]
    realm_path = "/admin/realms/" + realm
    try:
        api.request("GET", realm_path)
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise
        api.request("POST", "/admin/realms", {"realm": realm, "enabled": True, "registrationAllowed": False})
    for app, host, callback in applications:
        configure_client(api, realm_path, root, values, app, host, callback)
    print("Keycloak realm and selected OIDC clients configured.")


def configure_client(api, realm_path, root, values, app, host, callback):
    clients = api.request("GET", realm_path + "/clients?clientId=" + app)
    if len(clients) > 1:
        raise ProvisionError(f"Multiple {app} clients found; refusing to overwrite.")
    if clients and clients[0].get("attributes", {}).get("feuerwehr-stack-managed") != "true":
        raise ProvisionError(f"An unmanaged {app} client already exists; choose a different realm.")
    client = clients[0] if clients else {}
    client.update({
        "clientId": app, "name": "Feuerwehr " + app, "protocol": "openid-connect",
        "enabled": True, "publicClient": False, "bearerOnly": False,
        "standardFlowEnabled": True, "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": False, "serviceAccountsEnabled": False,
        "redirectUris": ["https://" + values[host] + callback],
        "webOrigins": [], "fullScopeAllowed": False,
        "defaultClientScopes": ["profile", "email"],
        "secret": read_secret(root, app + "_oidc_client_secret"),
    })
    client.setdefault("attributes", {})["feuerwehr-stack-managed"] = "true"
    if app in ("wehrportal", "synapse"):
        client["attributes"]["pkce.code.challenge.method"] = "S256"
    if clients:
        api.request("PUT", realm_path + "/clients/" + client["id"], client)
    else:
        api.request("POST", realm_path + "/clients", client)


def main():
    try:
        provision(Path(sys.argv[1]).resolve())
    except urllib.error.HTTPError as error:
        # Never log response bodies: they can contain credentials or tokens.
        print(f"ERROR: Keycloak provisioning failed (HTTP {error.code}). Check admin credentials "
              "and permissions; rerun scripts/setup-apps.sh.", file=sys.stderr)
        return 1
    except (ProvisionError, urllib.error.URLError, TimeoutError, OSError, KeyError, ValueError) as error:
        print(f"ERROR: Keycloak provisioning failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
