#!/usr/bin/env bash
# Runs the complete installer as root in a disposable container, without host Docker access.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ "${STACK_INSTALLER_TEST_CONTAINER:-false}" != true ]]; then
  exec docker run --rm --network none --tmpfs /test:exec,size=9g \
    -v "$ROOT:/source:ro" -e STACK_INSTALLER_TEST_CONTAINER=true \
    --entrypoint bash matrixdotorg/synapse:latest /source/tests/integration-installer.sh
fi

trap 'result=$?; cat /test/docker-calls >&2; exit "$result"' ERR
mkdir -p /test/bin
cat > /test/bin/docker <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> /test/docker-calls
case "$*" in
  'info --format {{.Swarm.ControlAvailable}}') echo false ;;
  'compose version'|'info'|'manifest inspect ghcr.io/timux/wehrportal:latest') ;;
  'stack ls --format {{.Name}}') ;;
  *'config --quiet')
    if [[ "${FAIL_CONFIG:-false}" == true ]]; then echo "Test configuration failure" >&2; exit 13; fi ;;
  *'up -d') ;;
  *) echo "Unexpected Docker invocation: $*" >&2; exit 1 ;;
esac
exit 0
EOF
chmod +x /test/bin/docker
export PATH="/test/bin:$PATH"
cat > /test/config.env <<'EOF'
BASE_DOMAIN=example.org
ENABLED_APPS=keycloak,wehrportal,matrix,onlyoffice,drupal
PROXY_MODE=remote
DEPLOY_MODE=compose
VPN_BACKEND_IP=10.20.0.5
ENABLE_PROXY_ROUTES=false
MAIL_HOST=smtp.example.org
MAIL_USERNAME=
MAIL_FROM_ADDRESS=portal@example.org
WEHRPORTAL_ADMIN_EMAILS=admin@example.org
DRUPAL_ADMIN_EMAIL=admin@example.org
EOF
bash "$ROOT/install.sh" --config /test/config.env --path /test/prepared --no-start --yes > /test/prepared.log
report=/test/prepared/installation-info.txt
[[ -f "$report" && "$(stat -c '%a' "$report")" == 600 ]]
grep -q 'NOCH NICHT gestartet' "$report"
grep -q 'https://login.example.org/admin/' "$report"
grep -q 'https://portal.example.org/anmelden/lokal' "$report"
grep -q 'https://messenger.example.org/' "$report"
grep -q 'https://www.example.org/user/login' "$report"
grep -q 'secrets/onlyoffice_jwt_secret' "$report"
if grep -q 'up -d' /test/docker-calls; then
  echo "--no-start started services." >&2; exit 1
fi
for secret in keycloak_admin_password drupal_admin_password onlyoffice_jwt_secret; do
  if grep -Fq "$(cat "/test/prepared/secrets/$secret")" /test/prepared.log "$report"; then
    echo "Installer leaked a secret." >&2; exit 1
  fi
done
sha256sum /test/prepared/secrets/keycloak_admin_password > /test/secret-before
bash "$ROOT/install.sh" --config /test/config.env --path /test/prepared --no-start --yes > /test/repeated.log
sha256sum --check /test/secret-before >/dev/null
grep -q 'NOCH NICHT gestartet' "$report"

sed 's/ENABLED_APPS=.*/ENABLED_APPS=onlyoffice/' /test/config.env > /test/office.env
bash "$ROOT/install.sh" --config /test/office.env --path /test/started --yes > /test/started.log
grep -q 'Dienste gestartet und ausgewaehlte Integrationen eingerichtet' /test/started/installation-info.txt
grep -q 'up -d' /test/docker-calls
if grep -q 'Keycloak - zentrale' /test/started/installation-info.txt; then
  echo "Summary listed an unselected application." >&2; exit 1
fi
result=0
FAIL_CONFIG=true bash "$ROOT/install.sh" --config /test/office.env --path /test/failed --yes \
  > /test/failed.log 2>&1 || result=$?
[[ "$result" == 13 && ! -e /test/failed/installation-info.txt ]]
grep -q 'Einrichtung nicht abgeschlossen' /test/failed.log
if grep -q 'Ihre Installation im Ueberblick' /test/failed.log; then
  echo "Failed installer printed a completion report." >&2; exit 1
fi
python3 - "$ROOT" <<'PY'
import os
from pathlib import Path
import pty
import subprocess
import sys

for confirmation, expected in (("ja", 0), ("nein", 1)):
    target = "/test/interactive-" + confirmation
    answers = [
        "https://example.org", "example.org",   # Domain: invalid, then valid.
        "ja", "nein", "nein", "nein", "nein",  # Only Keycloak.
        "", "invalid", "remote", "nein",      # Compose, proxy retry, no routes.
        "10.20.0.5", "", "",                   # VPN, admin, PostgreSQL image.
        "8192", "2", "", "", "", confirmation,  # Budget, realm, DNS, port, confirmation.
    ]
    master, slave = pty.openpty()
    process = subprocess.Popen(
        ["bash", sys.argv[1] + "/install.sh", "--path", target, "--no-start"],
        stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    os.close(slave)
    try:
        os.write(master, ("\n".join(answers) + "\n").encode())
        output, _ = process.communicate(timeout=30)
    finally:
        os.close(master)
        if process.poll() is None:
            process.kill()
            process.wait()
    assert process.returncode == expected, output
    assert "Ungueltige Eingabe" in output, output
    for unwanted in ("SMTP-Server fuer", "Matrix Federation:", "DNS-Subdomain unter example.org [matrix]"):
        assert unwanted not in output, output
    if expected == 0:
        assert "NOCH NICHT gestartet" in Path(target + "/installation-info.txt").read_text()
    else:
        assert not Path(target).exists(), output
PY
echo "Complete installer: prepared/started summaries, secret protection, repeat runs and failure status passed."
