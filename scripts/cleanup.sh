#!/usr/bin/env bash
# cleanup.sh — tidy what Pegasus *shows* without deleting any ROMs or media.
#
# Pegasus discovers games by each collection's `extensions:` glob, so multi-track
# discs (e.g. a PS1 `.cue` plus dozens of redbook-audio `.bin` tracks) get listed
# as dozens of junk "games". This re-syncs the `extensions:` line in each deployed
# `metadata.pegasus.txt` to the canonical set in `config/systems/<sys>.conf`,
# which excludes track-only formats — so the track files are simply no longer
# listed by Pegasus. The files stay on disk (the `.cue`/`.m3u` still references
# them), and your collection header, launch command, and any scraped game
# entries/artwork are left untouched.
#
# It NEVER deletes ROMs or media — it only rewrites one line per metadata file
# (after backing it up).
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
export PBC_SYSTEMS_DIR="$REPO_ROOT/config/systems"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=scripts/lib/pegasus.sh
source "$LIB_DIR/pegasus.sh"

CONFIG_FILE=""
ROMS_OVERRIDE=""
SYSTEM_ARG=""
usage() {
    cat <<EOF
Usage: scripts/cleanup.sh [OPTIONS]

Tidy the Pegasus library: re-sync each system's collection 'extensions:' line to
the catalog so non-game files (disc tracks like .bin, raw images) are no longer
listed by Pegasus. ROMs and media are never deleted — only the 'extensions:'
line is rewritten (after a backup), preserving launch commands and scraped data.

OPTIONS:
  -c, --config FILE   Read the ROM root from a deploy config.
      --roms DIR      ROM root to clean (overrides config; default \$HOME/ROMs or
                      a detected EmuDeck/ES-DE library).
      --system NAME   Only clean this system (e.g. psx); default: all deployed.
      --dry-run       Show what would change; write nothing.
  -y, --yes           Don't prompt for confirmation.
  -v, --verbose       Verbose output.
  -h, --help          This help.
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        --roms)      ROMS_OVERRIDE="${2:?--roms requires a path}"; shift 2 ;;
        --system)    SYSTEM_ARG="${2:?--system requires a name}"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

trap 'log_error "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"; exit 1' ERR

resolve_rom_root() {
    config_set_defaults
    [[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
    ROM_DIR="$CFG_ROM_ROOT"
    [[ -n "$ROMS_OVERRIDE" ]] && ROM_DIR="$ROMS_OVERRIDE"
    if [[ -z "$ROMS_OVERRIDE" && -z "$CONFIG_FILE" && "$ROM_DIR" == "$HOME/ROMs" ]] \
       && detect_rom_library; then
        ROM_DIR="$PBC_ROM_LIBRARY"
    fi
}

# canonical_extensions SHORTNAME -> the SYS_EXTENSIONS from its .conf.
canonical_extensions() { _sys_field "$1" SYS_EXTENSIONS; }

# current_extensions METAFILE -> the value after 'extensions:' (trimmed), or empty.
current_extensions() {
    local line; line="$(grep -m1 '^extensions:' "$1" 2>/dev/null || true)"
    trim "${line#extensions:}"
}

# clean_system SHORTNAME -> re-sync its metadata 'extensions:' line. Sets the
# global CLEAN_RESULT to changed|unchanged|nometa|noext. Must NOT be called via
# $(...) — it performs side effects (backup/write) that have to happen in the
# caller's shell so PBC_BACKUP_DIR persists.
CLEAN_RESULT=""
clean_system() {
    local sn="$1"
    local dirname; dirname="$(resolve_system_dirname "$sn" "$(_sys_field "$sn" SYS_DIRNAME)")"
    local meta="$ROM_DIR/$dirname/metadata.pegasus.txt"
    [[ -f "$meta" ]] || { CLEAN_RESULT=nometa; return 0; }
    local want cur; want="$(canonical_extensions "$sn")"; cur="$(current_extensions "$meta")"
    if [[ -z "$cur" ]]; then
        log_warn "$sn: no 'extensions:' line in $meta — skipping (non-standard file)"
        CLEAN_RESULT=noext; return 0
    fi
    if [[ "$cur" == "$want" ]]; then CLEAN_RESULT=unchanged; return 0; fi
    log_info "$sn: extensions '$cur' -> '$want'"
    backup_file "$meta"
    # Rewrite only the first 'extensions:' line; everything else is preserved.
    local new; new="$(awk -v ext="extensions: $want" '!d && /^extensions:/{print ext; d=1; next}{print}' "$meta")"
    printf '%s\n' "$new" | write_file "$meta"
    CLEAN_RESULT=changed
}

main() {
    log_init ""
    log_step "Pegasus library cleanup (re-sync collection extensions)"
    is_dry_run && log_warn "DRY-RUN MODE — nothing will be written"
    resolve_rom_root
    [[ -d "$ROM_DIR" ]] || die "ROM root not found: $ROM_DIR"
    log_info "ROM root: $ROM_DIR"

    # Which systems? A single one, or every catalogued system with metadata present.
    local systems=()
    if [[ -n "$SYSTEM_ARG" ]]; then
        [[ -r "$PBC_SYSTEMS_DIR/$SYSTEM_ARG.conf" ]] || die "unknown system '$SYSTEM_ARG'"
        systems=("$SYSTEM_ARG")
    else
        local f sn
        for f in "$PBC_SYSTEMS_DIR"/*.conf; do
            [[ -r "$f" ]] || continue
            sn="$(basename -- "$f" .conf)"; systems+=("$sn")
        done
    fi

    if [[ "$ASSUME_YES" != 1 ]] && ! is_dry_run; then
        ask_yes_no "Re-sync collection 'extensions:' for ${SYSTEM_ARG:-all systems} under $ROM_DIR? (ROMs/media untouched)" Y \
            || die "aborted by user"
    fi

    local changed=() unchanged=()
    local sn
    for sn in "${systems[@]}"; do
        clean_system "$sn"   # sets CLEAN_RESULT (not via $() — keeps backup state)
        case "$CLEAN_RESULT" in
            changed)   changed+=("$sn") ;;
            unchanged) unchanged+=("$sn") ;;
        esac
    done
    backup_finalize

    log_step "Cleanup summary"
    cat <<EOF
  Updated   : ${changed[*]:-（none）}
  Unchanged : ${unchanged[*]:-（none）}
  Backup    : ${PBC_BACKUP_DIR:-（none）}
  Note      : ROM and media files were not touched. Restart Pegasus to see the tidied library.
EOF
    is_dry_run && printf '\n%sThis was a DRY RUN — no metadata was changed.%s\n' "$C_YELLOW" "$C_RESET"
    return 0
}

main "$@"
