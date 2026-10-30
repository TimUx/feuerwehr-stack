#!/usr/bin/env python3
"""Exercise the actual installer prompts on a terminal and the secret-free report."""
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / "install.sh").read_text()


def function(name):
    start = INSTALLER.index(name + "() {")
    end = INSTALLER.index("\n}\n", start) + 3
    return INSTALLER[start:end]


class InstallerUITests(unittest.TestCase):
    def interact(self, command, answers):
        definitions = "\n".join(function(name) for name in (
            "prompt", "prompt_dns_host", "require_value", "valid_domain", "valid_private_ipv4", "prompt_for_app"))
        script = (
            "set -Eeuo pipefail\n"
            "declare -A values=() enabled=()\nDRY_RUN=false\n"
            "fail() { echo \"$*\" >&2; exit 1; }\n" + definitions + "\n" + command
        )
        master, slave = pty.openpty()
        try:
            process = subprocess.Popen(["bash", "-c", script], stdin=slave,
                                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            os.close(slave)
            slave = None
            os.write(master, answers.encode())
            output, _ = process.communicate(timeout=10)
            self.assertEqual(process.returncode, 0, output)
            return output
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_invalid_choices_retry_and_german_boolean(self):
        output = self.interact(
            'prompt PROXY_MODE "Proxy (own/same-host/remote)" own\n'
            'prompt MATRIX_FEDERATION "Federation" false\n'
            'printf "RESULT:%s:%s\\n" "${values[PROXY_MODE]}" "${values[MATRIX_FEDERATION]}"',
            "invalid\nremote\nja\n",
        )
        self.assertIn("Ungueltige Eingabe", output)
        self.assertIn("RESULT:remote:true", output)

    def test_domains_and_ports_retry(self):
        output = self.interact(
            'prompt BASE_DOMAIN "Domain" example.org\n'
            'values[BASE_DOMAIN]=example.org\nenabled[matrix]=1\napp_for_dns_prompt=matrix\n'
            'prompt_dns_host MATRIX_HOST "Matrix" matrix\n'
            'prompt MATRIX_PORT "Port" 18008\n'
            'printf "RESULT:%s:%s\\n" "${values[MATRIX_HOST]}" "${values[MATRIX_PORT]}"',
            "https://example.org\nexample.org\nbad.example.org\nchat\n80\n18008\n",
        )
        self.assertIn("keine URL oder vollstaendige Domain", output)
        self.assertIn("RESULT:chat.example.org:18008", output)

    def test_irrelevant_app_prompts_are_skipped(self):
        output = self.interact(
            'prompt_for_app wehrportal MAIL_HOST "SHOULD NOT ASK" ""\n'
            'prompt_for_app matrix MATRIX_FEDERATION "SHOULD NOT ASK" false\n'
            'printf "RESULT:%s:%s\\n" "${values[MAIL_HOST]}" "${values[MATRIX_FEDERATION]}"',
            "",
        )
        self.assertEqual(output, "RESULT::false\n")

    def test_required_input_and_explicit_empty_encryption(self):
        output = self.interact(
            'values[MAIL_HOST]=""\nrequire_value MAIL_HOST "SMTP erforderlich"\n'
            'prompt MAIL_ENCRYPTION "Verschluesselung" tls\n'
            'printf "RESULT:%s:%s\\n" "${values[MAIL_HOST]}" "${values[MAIL_ENCRYPTION]}"',
            "\nsmtp.example.org\n-\n",
        )
        self.assertIn("Dieses Feld ist erforderlich", output)
        self.assertIn("RESULT:smtp.example.org:", output)

    def test_vpn_and_admin_email_validation(self):
        output = self.interact(
            'prompt VPN_BACKEND_IP "Private IPv4 (z.B. 10.20.0.5)" ""\n'
            'prompt WEHRPORTAL_ADMIN_EMAILS "Admin-E-Mails" ""\n'
            'printf "RESULT:%s:%s\\n" "${values[VPN_BACKEND_IP]}" "${values[WEHRPORTAL_ADMIN_EMAILS]}"',
            "999.20.0.5\n8.8.8.8\n10.20.0.5\nbad-email\n a@example.org, b@example.org \n",
        )
        self.assertIn("RESULT:10.20.0.5:a@example.org,b@example.org", output)

    def summary(self, apps, no_start=False, emergency=False, routes=True):
        with tempfile.TemporaryDirectory() as root:
            secret_dir = Path(root) / "secrets"
            secret_dir.mkdir()
            sentinel = "never-print-this-secret-value"
            for name in ("mail_smtp_password", "keycloak_admin_password",
                         "drupal_admin_password", "onlyoffice_jwt_secret"):
                (secret_dir / name).write_text(sentinel)
            script = '''
set -Eeuo pipefail
declare -A values=(
 [DEPLOY_MODE]=compose [PROXY_MODE]=remote [ENABLE_PROXY_ROUTES]="$5"
 [KEYCLOAK_HOST]=login.example.org [KEYCLOAK_REALM]=feuerwehr [KEYCLOAK_ADMIN_USER]=kcadmin
 [WEHRPORTAL_HOST]=portal.example.org [WEHRPORTAL_ADMIN_EMAILS]=admin@example.org
 [MAIL_USERNAME]=smtp-user [WEHRPORTAL_OIDC_ENABLED]=true [WEHRPORTAL_OIDC_FORCE_DISABLED]="$4"
 [FLUFFYCHAT_HOST]=chat.example.org [MATRIX_HOST]=matrix.example.org
 [MATRIX_SERVER_NAME]=identity.example.org [MATRIX_OIDC_ENABLED]=true
 [ONLYOFFICE_HOST]=docs.example.org [DRUPAL_HOST]=www.example.org
 [DRUPAL_ADMIN_EMAIL]=siteadmin@example.org [DRUPAL_OIDC_ENABLED]=true
)
declare -A enabled=()
IFS=, read -r -a apps <<< "$2"
for app in "${apps[@]}"; do enabled[$app]=1; done
INSTALL_PATH=$1
NO_START=$3
source "$6/scripts/installation-summary.sh"
installation_summary
'''
            result = subprocess.run(
                ["bash", "-c", script, "test", root, apps,
                 str(no_start).lower(), str(emergency).lower(), str(routes).lower(), str(ROOT)],
                capture_output=True, text=True, check=True,
            )
            self.assertNotIn(sentinel, result.stdout)
            return result.stdout

    def test_all_application_urls_and_login_methods(self):
        output = self.summary("keycloak,wehrportal,matrix,onlyoffice,drupal")
        for expected in (
            "https://login.example.org/admin/", "Initialer Administrator: kcadmin",
            "/secrets/keycloak_admin_password", "https://portal.example.org/anmelden/lokal",
            "admin@example.org", "Kein lokales Passwort", "https://chat.example.org/",
            "https://matrix.example.org/", "@benutzer:identity.example.org",
            "https://docs.example.org/", "/secrets/onlyoffice_jwt_secret",
            "https://www.example.org/user/login", "siteadmin", "/secrets/drupal_admin_password",
            "integrations/traefik/dynamic.yml", "installation-info.txt",
        ):
            self.assertIn(expected, output)
        self.assertNotIn("NOCH NICHT", output)

    def test_prepared_state_emergency_and_disabled_routes(self):
        output = self.summary("keycloak,wehrportal", no_start=True, emergency=True, routes=False)
        self.assertIn("NOCH NICHT", output)
        self.assertIn("sudo ./scripts/update.sh --local-files", output)
        self.assertIn("OIDC_FORCE_DISABLED deaktiviert", output)
        self.assertIn("Proxy-Routen sind deaktiviert", output)
        self.assertNotIn("Drupal Website", output)
        self.assertNotIn("Chat im Browser", output)
        self.assertNotIn("Dienste gestartet und", output)

    def test_only_selected_applications_are_listed(self):
        output = self.summary("onlyoffice")
        self.assertIn("Ohne WehrPortal", output)
        for absent in ("Keycloak -", "Initialer Administrator", "Lokaler Adminzugang",
                       "Matrix Synapse", "Drupal Website"):
            self.assertNotIn(absent, output)


if __name__ == "__main__":
    unittest.main()
