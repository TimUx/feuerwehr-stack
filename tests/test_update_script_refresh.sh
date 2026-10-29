#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repository="$tmp/repository"
installation="$tmp/installation"
mkdir -p "$repository/scripts" "$installation/scripts" "$tmp/bin"
cp "$ROOT/compose.yml" "$repository/compose.yml"
cp "$ROOT/compose.yml" "$installation/compose.yml"
cp "$ROOT"/scripts/* "$repository/scripts/"
cp "$ROOT"/scripts/* "$installation/scripts/"
: > "$installation/.env"

cat > "$repository/scripts/update.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
printf '%s\n' "$*" > "$ROOT/restarted"
EOF
printf '#!/usr/bin/env bash\nprintf updated-backup\n' > "$repository/scripts/backup.sh"

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
output=
url=
while (($#)); do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
file=${url#*/main/}
cp "$MOCK_REPOSITORY/$file" "$output"
EOF
chmod +x "$tmp/bin/curl"

MOCK_REPOSITORY="$repository" PATH="$tmp/bin:$PATH" \
  bash "$installation/scripts/update.sh" --yes > "$tmp/output"

[[ "$(<"$installation/restarted")" == --yes ]]
[[ "$(<"$installation/scripts/backup.sh")" == $'#!/usr/bin/env bash\nprintf updated-backup' ]]
grep -q 'restarting it before continuing' "$tmp/output"
echo "Update script refresh and self-restart checks passed."
