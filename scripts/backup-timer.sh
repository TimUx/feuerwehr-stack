#!/usr/bin/env bash
# Installs or removes a systemd timer that runs scripts/backup.sh once a day.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
UNIT_DIR=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
UNIT=feuerwehr-backup
usage() {
  echo "Usage: $0 enable [--time HH:MM] [--keep N] | disable | status" >&2
  exit 2
}
action=${1:-}
[[ -n "$action" ]] || usage
shift
time=03:30
keep=14
while (($#)); do
  (($# >= 2)) || usage
  case "$1" in
    --time) time=$2 ;;
    --keep) keep=$2 ;;
    *) usage ;;
  esac
  shift 2
done
[[ "$time" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || { echo "--time must be HH:MM (24h)." >&2; exit 2; }
[[ "$keep" =~ ^[0-9]{1,4}$ ]] || { echo "--keep must be a number (0 keeps every backup)." >&2; exit 2; }
command -v systemctl >/dev/null || { echo "systemd (systemctl) is required for the backup timer." >&2; exit 1; }

case "$action" in
  enable)
    [[ -f "$ROOT/.env" && -x "$ROOT/scripts/backup.sh" ]] ||
      { echo "Not a valid installation directory: $ROOT" >&2; exit 1; }
    # systemd unit files are line based and treat % and quotes specially.
    [[ "$ROOT" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
      { echo "Installation path contains characters that are unsafe in a systemd unit: $ROOT" >&2; exit 1; }
    cat > "$UNIT_DIR/$UNIT.service" <<EOF
[Unit]
Description=Feuerwehr stack backup
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
Environment=BACKUP_KEEP=$keep
ExecStart=$ROOT/scripts/backup.sh
EOF
    cat > "$UNIT_DIR/$UNIT.timer" <<EOF
[Unit]
Description=Daily Feuerwehr stack backup

[Timer]
OnCalendar=*-*-* $time:00
Persistent=true

[Install]
WantedBy=timers.target
EOF
    chmod 0644 "$UNIT_DIR/$UNIT.service" "$UNIT_DIR/$UNIT.timer"
    systemctl daemon-reload
    systemctl enable --now "$UNIT.timer"
    echo "Daily backup enabled at $time, keeping the newest $keep archives (0 = all) in $ROOT/backups."
    echo "Applications are stopped briefly during each backup. Copy archives off this host yourself."
    ;;
  disable)
    systemctl disable --now "$UNIT.timer" 2>/dev/null || true
    rm -f -- "${UNIT_DIR:?}/${UNIT:?}.service" "${UNIT_DIR:?}/${UNIT:?}.timer"
    systemctl daemon-reload
    echo "Daily backup disabled; existing archives are kept."
    ;;
  status)
    systemctl list-timers "$UNIT.timer" --all --no-pager
    systemctl status "$UNIT.service" --no-pager --lines 5 || true
    ;;
  *) usage ;;
esac
