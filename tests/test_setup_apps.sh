#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/scripts" "$tmp/bin"
cp "$ROOT/scripts/setup-apps.sh" "$ROOT/scripts/setup-wehrportal.sh" "$ROOT/scripts/setup-synapse.sh" \
  "$ROOT/scripts/setup-wehrportal-office.sh" "$tmp/scripts/"
cat > "$tmp/scripts/lib.sh" <<'EOF'
env_value() { sed -n "s/^$1=//p" "$ROOT/.env" | head -n 1; }
DEPLOY_MODE=$(env_value DEPLOY_MODE)
compose=(mock-compose)
swarm_container() { echo "test-$1"; }
EOF
cat > "$tmp/scripts/configure-keycloak.py" <<'PY'
import os
from pathlib import Path
with (Path(__file__).parent.parent / "order").open("a") as log:
    log.write("keycloak\n")
if os.environ.get("FAIL_KEYCLOAK"):
    raise SystemExit(1)
PY
printf '#!/usr/bin/env bash\necho drupal >> "$(dirname "$0")/../order"\n' > "$tmp/scripts/setup-drupal.sh"
cat > "$tmp/bin/mock-compose" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/order"
if [[ "$*" == *synapse* ]]; then exit "${MATRIX_RESULT:-0}"; fi
exit "${PORTAL_RESULT:-0}"
EOF
cp "$tmp/bin/mock-compose" "$tmp/bin/docker"
chmod +x "$tmp/scripts/"*.sh "$tmp/bin/"*
printf '#!/usr/bin/env bash\nexit 0\n' > "$tmp/bin/sleep"
chmod +x "$tmp/bin/sleep"
export TEST_ROOT="$tmp"
export PATH="$tmp/bin:$PATH"
for mode in compose swarm; do
  for app in none portal both; do
    : > "$tmp/order"
    printf 'DEPLOY_MODE=%s\n' "$mode" > "$tmp/.env"
    if [[ "$app" != none ]]; then printf 'WEHRPORTAL_OIDC_ENABLED=true\n' >> "$tmp/.env"; fi
    if [[ "$app" == both ]]; then printf 'DRUPAL_OIDC_ENABLED=true\n' >> "$tmp/.env"; fi
    "$tmp/scripts/setup-apps.sh"
    python3 - "$tmp/order" "$mode" "$app" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
if sys.argv[3] == "none":
    assert lines == ["drupal"], lines
else:
    assert lines[:2] == ["keycloak", "drupal"], lines
    assert len(lines) == 4, lines
    assert lines[2].endswith("configure-wehrportal-oidc.php --check"), lines
    assert lines[3].endswith("configure-wehrportal-oidc.php"), lines
    assert lines[2].startswith("exec -T wehrportal " if sys.argv[2] == "compose" else "exec test-wehrportal "), lines
PY
  done
done
for mode in compose swarm; do
  for app in matrix all; do
    : > "$tmp/order"
    printf 'DEPLOY_MODE=%s\nMATRIX_OIDC_ENABLED=true\n' "$mode" > "$tmp/.env"
    if [[ "$app" == all ]]; then
      printf 'WEHRPORTAL_OIDC_ENABLED=true\nDRUPAL_OIDC_ENABLED=true\n' >> "$tmp/.env"
    fi
    "$tmp/scripts/setup-apps.sh" >/dev/null
    python3 - "$tmp/order" "$mode" "$app" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
assert lines[:2] == ["keycloak", "drupal"], lines
prefix = "exec -T synapse " if sys.argv[2] == "compose" else "exec test-synapse "
assert any(line.startswith(prefix) for line in lines), lines
assert "oidc-keycloak" in "\n".join(lines), lines
assert sum("configure-wehrportal-oidc.php" in line for line in lines) == \
    (2 if sys.argv[3] == "all" else 0), lines
PY
  done
done
for mode in compose swarm; do
  for apps in wehrportal onlyoffice wehrportal,onlyoffice; do
    : > "$tmp/order"
    printf 'DEPLOY_MODE=%s\nENABLED_APPS=%s\n' "$mode" "$apps" > "$tmp/.env"
    "$tmp/scripts/setup-apps.sh"
    python3 - "$tmp/order" "$mode" "$apps" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
if sys.argv[3] != "wehrportal,onlyoffice":
    assert lines == ["drupal"], lines
else:
    assert lines[0] == "drupal" and len(lines) == 3, lines
    prefix = "exec -T wehrportal " if sys.argv[2] == "compose" else "exec test-wehrportal "
    assert lines[1] == prefix + "php /stack/configure-wehrportal-office.php --check", lines
    assert lines[2] == prefix + "php /stack/configure-wehrportal-office.php", lines
PY
  done
done
if PORTAL_RESULT=1 "$tmp/scripts/setup-wehrportal-office.sh" >/dev/null 2>&1; then
  echo "Office setup ignored a compatibility failure." >&2; exit 1
fi
if PORTAL_RESULT=75 "$tmp/scripts/setup-wehrportal-office.sh" > "$tmp/office-result" 2>&1; then
  echo "Office setup ignored a readiness timeout." >&2; exit 1
fi
grep -q 'ONLYOFFICE did not become ready' "$tmp/office-result"
: > "$tmp/order"
printf 'DEPLOY_MODE=compose\nWEHRPORTAL_OIDC_ENABLED=true\n' > "$tmp/.env"
if FAIL_KEYCLOAK=true "$tmp/scripts/setup-apps.sh" >/dev/null 2>&1; then
  echo "Application setup ignored Keycloak failure." >&2; exit 1
fi
[[ "$(<"$tmp/order")" == keycloak ]]
if PORTAL_RESULT=1 "$tmp/scripts/setup-wehrportal.sh" >/dev/null 2>&1; then
  echo "Application setup ignored an incompatible portal." >&2; exit 1
fi
printf 'DEPLOY_MODE=compose\nMATRIX_OIDC_ENABLED=true\n' > "$tmp/.env"
: > "$tmp/order"
if MATRIX_RESULT=1 "$tmp/scripts/setup-synapse.sh" > "$tmp/matrix-result" 2>&1; then
  echo "Application setup ignored a Synapse SSO readiness failure." >&2; exit 1
fi
grep -q 'Synapse SSO did not become ready' "$tmp/matrix-result"
[[ "$(grep -c '^exec -T synapse ' "$tmp/order")" == 120 ]]
echo "Shared application setup ordering and failure checks passed for Compose and Swarm."
