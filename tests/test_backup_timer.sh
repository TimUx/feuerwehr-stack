#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp=$(mktemp -d)
trap 'rm -rf -- "${tmp:?}"' EXIT

installation="$tmp/installation"
units="$tmp/units"
mkdir -p "$installation/scripts" "$installation/backups" "$units" "$tmp/bin"
cp "$ROOT/scripts/backup.sh" "$ROOT/scripts/backup-timer.sh" "$ROOT/scripts/lib.sh" "$installation/scripts/"
printf 'ENABLED_APPS=\n' > "$installation/.env"

cat > "$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
EOF
# Minimal Docker stand-in: a running PostgreSQL container and no application services.
cat > "$tmp/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *'ps --services --status running') ;;
  *'ps -q postgres') echo postgres-container ;;
  inspect*) echo postgres:test ;;
  *'SHOW server_version') echo 18.0 ;;
  *) echo "Unexpected Docker invocation: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/systemctl" "$tmp/bin/docker"
export PATH="$tmp/bin:$PATH" SYSTEMCTL_LOG="$tmp/systemctl.log" SYSTEMD_UNIT_DIR="$units"
timer="$installation/scripts/backup-timer.sh"

"$timer" enable --time 02:15 --keep 3 > "$tmp/output"
grep -qx "ExecStart=$installation/scripts/backup.sh" "$units/feuerwehr-backup.service"
grep -qx 'Environment=BACKUP_KEEP=3' "$units/feuerwehr-backup.service"
grep -qx 'OnCalendar=\*-\*-\* 02:15:00' "$units/feuerwehr-backup.timer"
grep -qx 'Persistent=true' "$units/feuerwehr-backup.timer"
grep -qx 'enable --now feuerwehr-backup.timer' "$SYSTEMCTL_LOG"
"$timer" enable > /dev/null
grep -qx 'OnCalendar=\*-\*-\* 03:30:00' "$units/feuerwehr-backup.timer"
grep -qx 'Environment=BACKUP_KEEP=14' "$units/feuerwehr-backup.service"

for arguments in "enable --time 25:00" "enable --time 3:30" "enable --keep many" "enable --keep" "start" ""; do
  # shellcheck disable=SC2086
  if "$timer" $arguments > /dev/null 2>&1; then
    echo "Invalid arguments were accepted: $arguments" >&2
    exit 1
  fi
done

"$timer" disable > /dev/null
[[ ! -e "$units/feuerwehr-backup.service" && ! -e "$units/feuerwehr-backup.timer" ]]
grep -qx 'disable --now feuerwehr-backup.timer' "$SYSTEMCTL_LOG"

# Rotation: only archives created by a rotating run are pruned. Imported archives with the same
# naming scheme, manual runs without BACKUP_KEEP and unrelated files are never deleted.
for day in 01 02; do
  touch "$installation/backups/feuerwehr-202601${day}T030000Z.tar.gz"
done
touch "$installation/backups/manual-copy.tar.gz" "$installation/backups/feuerwehr-notes.tar.gz"
"$installation/scripts/backup.sh" > /dev/null
[[ ! -e "$installation/backups/.rotation" ]]
for _ in 1 2 3 4; do
  sleep 1
  BACKUP_KEEP=2 "$installation/scripts/backup.sh" > "$tmp/output"
done
[[ $(grep -c '^Removed old backup: ' "$tmp/output") -eq 1 ]]
[[ $(find "$installation/backups" -name 'feuerwehr-2*.tar.gz' | wc -l) -eq 5 ]]
[[ -e "$installation/backups/feuerwehr-20260101T030000Z.tar.gz" &&
   -e "$installation/backups/feuerwehr-20260102T030000Z.tar.gz" ]]
mapfile -t kept < "$installation/backups/.rotation"
[[ ${#kept[@]} -eq 2 && -f "$installation/backups/${kept[0]}" && -f "$installation/backups/${kept[1]}" ]]
[[ -e "$installation/backups/manual-copy.tar.gz" && -e "$installation/backups/feuerwehr-notes.tar.gz" ]]
tar -tzf "$installation/backups/${kept[0]}" | grep -qx './manifest.txt'
# Entries that are not plain archive names of this script are ignored, never followed.
touch "$tmp/outside.tar.gz"
printf '%s\n' "../../outside.tar.gz" "$tmp/outside.tar.gz" >> "$installation/backups/.rotation"
sleep 1
BACKUP_KEEP=1 "$installation/scripts/backup.sh" > /dev/null
[[ -e "$tmp/outside.tar.gz" && $(wc -l < "$installation/backups/.rotation") -eq 1 ]]
if BACKUP_KEEP=all "$installation/scripts/backup.sh" > /dev/null 2>&1; then
  echo "Invalid BACKUP_KEEP was accepted." >&2
  exit 1
fi
echo "Backup timer and rotation checks passed."
