#!/usr/bin/env python3
"""Unit tests for idempotent realm/client provisioning without a live server."""
import importlib.util
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "configure_keycloak", Path(__file__).resolve().parents[1] / "scripts/configure-keycloak.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "secrets").mkdir()
        for name in ("keycloak_admin_password", "drupal_oidc_client_secret", "wehrportal_oidc_client_secret", "synapse_oidc_client_secret"):
            (self.root / "secrets" / name).write_text("test-only-" + name)
        (self.root / ".env").write_text(
            "KEYCLOAK_HOST=login.example.org\nKEYCLOAK_REALM=feuerwehr\n"
            "KEYCLOAK_ADMIN_USER=kcadmin\nDRUPAL_HOST=www.example.org\n"
            "DRUPAL_OIDC_ENABLED=true\nWEHRPORTAL_HOST=portal.example.org\n")
        self.clients = []
        self.realm_exists = False
        self.calls = []

    def request(self, api, method, path, data=None, form=False):
        self.calls.append((method, path, data))
        if path.endswith("openid-configuration"):
            return {}
        if path.endswith("/token"):
            return {"access_token": "test-token"}
        if path == "/admin/realms/feuerwehr" and not self.realm_exists:
            raise urllib.error.HTTPError(path, 404, "not found", {}, None)
        if path == "/admin/realms" and method == "POST":
            self.realm_exists = True
        if "?clientId" in path:
            client_id = path.split("?clientId=")[1]
            return [c for c in self.clients if c.get("clientId", client_id) == client_id]
        if path.endswith("/clients") and method == "POST":
            self.clients.append(dict(data, id="id-" + data["clientId"]))
        if "/clients/id-" in path:
            self.clients = [data if c["id"] == data["id"] else c for c in self.clients]
        return {}

    def test_create_and_repeat(self):
        with patch.object(module.Keycloak, "request", autospec=True, side_effect=self.request):
            module.provision(self.root)
            module.provision(self.root)
        self.assertEqual(len(self.clients), 1)
        client = self.clients[0]
        self.assertEqual(client["redirectUris"], ["https://www.example.org/openid-connect/generic"])
        self.assertFalse(client["directAccessGrantsEnabled"])
        self.assertFalse(client["publicClient"])
        self.assertEqual(client["secret"], "test-only-drupal_oidc_client_secret")
        self.assertEqual(sum(m == "POST" and p.endswith("/clients") for m, p, _ in self.calls), 1)
        self.assertEqual(sum(m == "PUT" for m, _, _ in self.calls), 1)

    def test_application_selection(self):
        for apps in ((), ("wehrportal",), ("synapse",), ("drupal", "wehrportal", "synapse")):
            with self.subTest(apps=apps):
                self.clients = []
                self.calls = []
                config = self.root / ".env"
                config.write_text("KEYCLOAK_HOST=login.example.org\nKEYCLOAK_REALM=feuerwehr\n"
                                  "KEYCLOAK_ADMIN_USER=kcadmin\nDRUPAL_HOST=www.example.org\n"
                                  "WEHRPORTAL_HOST=portal.example.org\nMATRIX_HOST=matrix.example.org\n" +
                                  "".join(("MATRIX" if app == "synapse" else app.upper()) + "_OIDC_ENABLED=true\n" for app in apps))
                with patch.object(module.Keycloak, "request", autospec=True, side_effect=self.request):
                    module.provision(self.root)
                    module.provision(self.root)
                self.assertEqual({c["clientId"] for c in self.clients}, set(apps))
                for client in self.clients:
                    self.assertEqual(client["secret"], "test-only-" + client["clientId"] + "_oidc_client_secret")
                    if client["clientId"] == "wehrportal":
                        self.assertEqual(client["redirectUris"], ["https://portal.example.org/auth/oidc/callback"])
                        self.assertEqual(client["attributes"]["pkce.code.challenge.method"], "S256")
                    if client["clientId"] == "synapse":
                        self.assertEqual(client["redirectUris"], ["https://matrix.example.org/_synapse/client/oidc/callback"])
                        self.assertEqual(client["attributes"]["pkce.code.challenge.method"], "S256")
                if not apps:
                    self.assertEqual(self.calls, [])

    def test_unmanaged_client_is_not_overwritten(self):
        self.clients = [{"id": "manual"}]
        with patch.object(module.Keycloak, "request", autospec=True, side_effect=self.request):
            with self.assertRaises(module.ProvisionError):
                module.provision(self.root)
        self.assertFalse(any(m == "PUT" for m, _, _ in self.calls))

    def test_readiness_failure_is_not_swallowed(self):
        error = urllib.error.HTTPError("url", 401, "unauthorized", {}, None)
        with patch.object(module.Keycloak, "request", side_effect=error):
            # HTTP errors on readiness are retried; authentication failures afterward propagate.
            with patch.object(module.time, "monotonic", side_effect=[0, 181]):
                with self.assertRaises(module.ProvisionError):
                    module.provision(self.root)

    def test_auth_failure_is_not_swallowed(self):
        error = urllib.error.HTTPError("url", 401, "unauthorized", {}, None)
        with patch.object(module.Keycloak, "request", side_effect=[{}, error]):
            with self.assertRaises(urllib.error.HTTPError):
                module.provision(self.root)

    def test_secret_symlinks_are_rejected(self):
        path = self.root / "secrets" / "drupal_oidc_client_secret"
        path.unlink()
        path.symlink_to(self.root / ".env")
        with self.assertRaises(module.ProvisionError):
            module.read_secret(self.root, "drupal_oidc_client_secret")


if __name__ == "__main__":
    unittest.main()
