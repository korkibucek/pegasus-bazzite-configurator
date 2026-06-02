#!/usr/bin/env bash
# restore.sh — restore Pegasus configuration/metadata from a timestamped
# backup created by deploy.sh. With no argument it restores the most recent
# backup. Supports --dry-run and --list.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB_DIR/detect.sh"   # for backup_finalize's os_summary_line (harmless)
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB_DIR/backup.sh"

DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --list)
            r="$(backup_root)"
            if [[ -d "$r" ]]; then
                echo "Available backups under $r:"
                find "$r" -mindepth 1 -maxdepth 1 -type d | sort
            else
                echo "No backups found under $r"
            fi
            exit 0 ;;
        -h|--help)
            cat <<EOF
Usage: scripts/restore.sh [BACKUP_DIR] [--dry-run] [--list]

With no BACKUP_DIR, restores the most recent backup.
  --list      List available backups and exit.
  --dry-run   Show what would be restored without writing.
EOF
            exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) DIR="$1"; shift ;;
    esac
done

config_set_defaults
log_init ""
is_dry_run && log_warn "DRY-RUN MODE — no files will be restored"
backup_restore "$DIR"
