#!/usr/bin/env python3
"""Test managed config mutations without adding PyYAML as a host dependency."""
import json
import os
from pathlib import Path
import runpy
import tempfile
import types
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/configure-synapse.py"


class SynapseConfigTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.config = Path(self.directory.name) / "homeserver.yaml"
        self.config.write_text(json.dumps({
            "allow_registration": True,
            "listeners": [{"resources": [{"names": ["client", "federation"]}]}],
            "oidc_providers": [{"idp_id": "other", "issuer": "https://other.example"}],
            "sso": {"client_whitelist": ["https://other-client.example/"]},
        }))
        self.env = {
            "SYNAPSE_CONFIG_PATH": str(self.config), "SYNAPSE_SERVER_NAME": "identity.example.org",
            "MATRIX_HOST": "matrix.example.org", "FLUFFYCHAT_HOST": "chat.example.org",
            "KEYCLOAK_HOST": "login.example.org", "KEYCLOAK_REALM": "feuerwehr",
            "MATRIX_OIDC_ENABLED": "true",
        }

    def configure(self, secret="private-client-secret"):
        original_read = Path.read_text
        original_exists = Path.is_file

        def read(path, *args, **kwargs):
            if str(path) == "/run/secrets/synapse_oidc_client_secret":
                return secret
            if str(path) == "/run/secrets/synapse_db_password":
                return "database-password"
            return original_read(path, *args, **kwargs)

        def exists(path):
            if str(path) == "/run/secrets/synapse_oidc_client_secret":
                return secret is not None
            return original_exists(path)

        yaml = types.SimpleNamespace(safe_load=json.loads, safe_dump=json.dumps)
        with patch.dict(os.environ, self.env, clear=True), patch.dict("sys.modules", {"yaml": yaml}), \
                patch.object(Path, "read_text", read), patch.object(Path, "is_file", exists), \
                patch("os.fchown"):
            runpy.run_path(str(SCRIPT), run_name="__main__")
        return json.loads(self.config.read_text())

    def test_provider_and_secret_reference(self):
        data = self.configure()
        provider = data["oidc_providers"][-1]
        self.assertEqual(provider["issuer"], "https://login.example.org/realms/feuerwehr")
        self.assertEqual(provider["client_id"], "synapse")
        self.assertEqual(provider["client_secret_path"], "/run/secrets/synapse_oidc_client_secret")
        self.assertNotIn("private-client-secret", self.config.read_text())
        self.assertFalse(provider["allow_existing_users"])
        self.assertTrue(provider["enable_registration"])
        self.assertEqual(provider["pkce_method"], "always")
        self.assertEqual(provider["user_mapping_provider"]["config"]["subject_claim"], "sub")
        self.assertFalse(data["enable_registration"])
        self.assertNotIn("allow_registration", data)
        self.assertEqual(data["public_baseurl"], "https://matrix.example.org/")
        self.assertEqual(data["server_name"], "identity.example.org")
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(data["listeners"][0]["resources"][0]["names"], ["client"])

    def test_idempotence_and_preservation(self):
        data = self.configure()
        self.assertEqual(self.configure(), data)
        self.assertEqual(data["oidc_providers"][0]["idp_id"], "other")
        self.assertEqual(data["sso"]["client_whitelist"],
                         ["https://other-client.example/", "https://chat.example.org/"])

    def test_hostname_change_and_disable(self):
        self.configure()
        self.env["FLUFFYCHAT_HOST"] = "new-chat.example.org"
        data = self.configure()
        self.assertNotIn("https://chat.example.org/", data["sso"]["client_whitelist"])
        self.assertIn("https://new-chat.example.org/", data["sso"]["client_whitelist"])
        self.env["MATRIX_OIDC_ENABLED"] = "false"
        data = self.configure()
        self.assertEqual([p["idp_id"] for p in data["oidc_providers"]], ["other"])
        self.assertEqual(data["sso"]["client_whitelist"], ["https://other-client.example/"])
        self.assertNotIn("feuerwehr_stack_sso_client_origin", data)
        self.assertFalse(data["enable_registration"])

    def test_empty_secret_fails_without_overwriting(self):
        before = self.config.read_text()
        for secret in ("", " \n", None):
            with self.subTest(secret=secret), self.assertRaisesRegex(RuntimeError, "Missing or empty"):
                self.configure(secret=secret)
        self.assertEqual(self.config.read_text(), before)


if __name__ == "__main__":
    unittest.main()
