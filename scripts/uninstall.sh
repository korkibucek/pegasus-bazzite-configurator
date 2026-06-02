#!/usr/bin/env bash
# uninstall.sh — cleanly undo a deployment.
#
# Removes the files THIS TOOL generated and (opt-in) the Flatpaks it installed.
# It NEVER touches your ROM files or your media/artwork — only the generated
# metadata.pegasus.txt / HOW_TO_ADD_ROMS.txt and our entries in game_dirs.txt.
# Everything removed is backed up first (unless --no-backup), so it is
# reversible via restore.sh.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
export PBC_SYSTEMS_DIR="$REPO_ROOT/config/systems"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=scripts/lib/emulators.sh
source "$LIB_DIR/emulators.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=scripts/lib/pegasus.sh
source "$LIB_DIR/pegasus.sh"

CONFIG_FILE=""
REMOVE_FLATPAKS=0
OPT_NO_BACKUP=0   # CLI flag; applied AFTER config load so it wins over the file
PBC_REMOVED=0

usage() {
    cat <<EOF
Usage: scripts/uninstall.sh [OPTIONS]

Remove the configuration this tool generated. ROM files and media are NEVER
touched. Generated files are backed up before removal (restore with restore.sh).

OPTIONS:
  -c, --config FILE     Use the same config you deployed with (recommended, so
                        the correct systems/emulators are targeted).
      --remove-flatpaks Also 'flatpak uninstall --user' the configured emulators
                        AND Pegasus. Off by default.
      --no-backup       Do not back up before removing (not recommended).
      --dry-run         Show what would be removed; change nothing.
  -y, --yes             Do not prompt for confirmation.
  -v, --verbose         Verbose output.
  -h, --help            This help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)       CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        --remove-flatpaks) REMOVE_FLATPAKS=1; shift ;;
        --no-backup)       OPT_NO_BACKUP=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        -y|--yes)          ASSUME_YES=1; shift ;;
        -v|--verbose)      VERBOSE=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

trap 'log_error "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"; exit 1' ERR

main() {
    config_set_defaults
    [[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
    # CLI --no-backup wins over the config file's 'backup' value.
    [[ "$OPT_NO_BACKUP" == 1 ]] && CFG_BACKUP=no
    detect_all
    pegasus_resolve_config_dir
    log_init ""
    is_dry_run && log_warn "DRY-RUN MODE — nothing will be removed"

    local systems; mapfile -t systems < <(pegasus_resolve_systems)
    log_step "Uninstall plan"
    cat <<EOF
  ROM root        : $CFG_ROM_ROOT  (ROM files & media are preserved)
  Config dir      : $PEGASUS_CONFIG_DIR
  Systems         : ${systems[*]:-（none）}
  Remove Flatpaks : $([[ "$REMOVE_FLATPAKS" == 1 ]] && echo "yes — ${CFG_EMULATORS} + Pegasus" || echo "no (config only)")
EOF
    if [[ "$ASSUME_YES" != 1 ]] && ! is_dry_run; then
        ask_yes_no "Proceed with uninstall?" N || die "aborted by user"
    fi

    # 1) Remove generated per-system files (backed up first).
    log_step "Removing generated metadata"
    local sn dir managed=()
    for sn in "${systems[@]}"; do
        dir="$CFG_ROM_ROOT/$(_sys_field "$sn" SYS_DIRNAME)"
        managed+=("$dir")
        local f
        for f in "$dir/metadata.pegasus.txt" "$dir/HOW_TO_ADD_ROMS.txt"; do
            if [[ -e "$f" ]]; then
                backup_file "$f"
                run_cmd rm -f -- "$f"
                PBC_REMOVED=$((PBC_REMOVED+1))
                log_ok "removed $f"
            fi
        done
    done

    # 2) Deregister our game-dir entries (keep any the user added themselves).
    log_step "Deregistering game directories"
    local gd="$PEGASUS_CONFIG_DIR/game_dirs.txt"
    if [[ -f "$gd" ]]; then
        backup_file "$gd"
        local kept="" line keep
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -z "$line" ]] && continue
            keep=1
            for dir in "${managed[@]}"; do [[ "$line" == "$dir" ]] && { keep=0; break; }; done
            [[ "$keep" == 1 ]] && kept+="${kept:+$'\n'}$line"
        done <"$gd"
        if [[ -n "$kept" ]]; then
            printf '%s\n' "$kept" | write_file "$gd"
            log_ok "rewrote $gd (kept user-added entries)"
        else
            run_cmd rm -f -- "$gd"
            log_ok "removed $gd (no entries remained)"
        fi
    else
        log_info "no game_dirs.txt to update"
    fi

    # 3) Optional Flatpak removal.
    if [[ "$REMOVE_FLATPAKS" == 1 ]]; then
        log_step "Removing Flatpaks"
        if ! have flatpak && ! is_dry_run; then
            log_warn "flatpak not present; skipping Flatpak removal"
        else
            local k
            for k in $CFG_EMULATORS; do
                emu_exists "$k" || continue
                run_cmd flatpak uninstall --user --noninteractive "${EMU_ID[$k]}" \
                    || log_warn "could not uninstall ${EMU_ID[$k]} (maybe not installed)"
            done
            if [[ "$CFG_PEGASUS_INSTALL" != skip ]]; then
                run_cmd flatpak uninstall --user --noninteractive "$PEGASUS_FLATPAK_ID" \
                    || log_warn "could not uninstall $PEGASUS_FLATPAK_ID (maybe not installed)"
            fi
        fi
    fi

    backup_finalize
    log_step "Uninstall summary"
    cat <<EOF
  Generated files removed : $PBC_REMOVED
  Flatpaks removed        : $([[ "$REMOVE_FLATPAKS" == 1 ]] && echo "yes" || echo "no")
  Backup                  : ${PBC_BACKUP_DIR:-（none）}
  ROM files / media       : preserved
  Restore                 : scripts/restore.sh${PBC_BACKUP_DIR:+ "$PBC_BACKUP_DIR"}
EOF
    is_dry_run && printf '\n%sThis was a DRY RUN — nothing was removed.%s\n' "$C_YELLOW" "$C_RESET"
    return 0
}

main "$@"
