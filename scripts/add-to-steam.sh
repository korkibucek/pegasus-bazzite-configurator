#!/usr/bin/env bash
# add-to-steam.sh — OPT-IN helper that adds Pegasus to Steam as a non-Steam
# game so it can be launched from Game Mode on a Steam Deck / handheld.
#
# SAFETY: Steam stores shortcuts in a BINARY file (shortcuts.vdf). Corrupting it
# would lose your other non-Steam shortcuts, so this:
#   * refuses to run while Steam is open (Steam rewrites the file on exit),
#   * backs up shortcuts.vdf before any change (restore with restore.sh),
#   * appends idempotently via a stdlib Python parser (lib/steam_shortcuts.py)
#     that preserves all existing entries,
#   * supports --dry-run.
# Final Game-Mode verification requires real hardware (see docs/TESTING.md).
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB_DIR/backup.sh"

VDF_TOOL="$LIB_DIR/steam_shortcuts.py"
APP_NAME="Pegasus"
PEGASUS_ID="$PEGASUS_FLATPAK_ID"
STEAM_ROOT_OVERRIDE=""

usage() {
    cat <<EOF
Usage: scripts/add-to-steam.sh [--name NAME] [--dry-run] [-y] [-v]

Add Pegasus to Steam as a non-Steam game (for launching from Game Mode).

  --name NAME       Shortcut name (default: Pegasus)
  --steam-root DIR  Steam data root override (auto-detected otherwise)
  --dry-run         Show what would change; write nothing.
  -y, --yes         Do not prompt for confirmation.
  -v, --verbose     Verbose output.

Steam must be CLOSED. Your shortcuts.vdf is backed up before any change.
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        --name)       APP_NAME="${2:?}"; shift 2 ;;
        --steam-root) STEAM_ROOT_OVERRIDE="${2:?}"; shift 2 ;;
        --dry-run)    DRY_RUN=1; shift ;;
        -y|--yes)     ASSUME_YES=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

trap 'log_error "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"; exit 1' ERR

# steam_config_dirs — echo each existing Steam userdata <id>/config directory.
steam_config_dirs() {
    local roots=()
    if [[ -n "$STEAM_ROOT_OVERRIDE" ]]; then
        roots+=("$STEAM_ROOT_OVERRIDE")
    else
        roots+=("$HOME/.steam/steam" "$HOME/.local/share/Steam" \
                "$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam" \
                "$HOME/.steam/root")
    fi
    local r d
    for r in "${roots[@]}"; do
        for d in "$r"/userdata/*/config; do
            [[ -d "$d" ]] && printf '%s\n' "$d"
        done
    done
}

main() {
    config_set_defaults
    detect_all
    log_init ""
    is_dry_run && log_warn "DRY-RUN MODE — nothing will be written"

    have python3 || die "python3 is required (it ships in the Fedora/Bazzite base)"
    [[ -r "$VDF_TOOL" ]] || die "missing $VDF_TOOL"

    # Guard: Steam must not be running (it would overwrite our change on exit).
    if ! is_dry_run && have pgrep && pgrep -x steam >/dev/null 2>&1; then
        die "Steam appears to be running — close Steam completely, then re-run (it rewrites shortcuts.vdf on exit)"
    fi

    local dirs; mapfile -t dirs < <(steam_config_dirs)
    if [[ ${#dirs[@]} -eq 0 ]]; then
        die "no Steam user data found. Launch Steam once and log in, then re-run (or pass --steam-root)."
    fi

    # Resolve how to launch Pegasus.
    local exe launch flatpak_id="" startdir="$HOME"
    if flatpak info "$PEGASUS_ID" >/dev/null 2>&1 || [[ "$CFG_PEGASUS_INSTALL" == flatpak ]]; then
        local fp; fp="$(command -v flatpak || echo /usr/bin/flatpak)"
        exe="\"$fp\""; launch="run $PEGASUS_ID"; flatpak_id="$PEGASUS_ID"
    else
        local app; app="$(compgen -G "$HOME/Applications/*egasus*.AppImage" | head -n1 || true)"
        [[ -n "$app" ]] || app="$HOME/Applications/Pegasus.AppImage"
        exe="\"$app\""; launch=""
    fi

    log_step "Add Pegasus to Steam"
    log_info "Shortcut: $APP_NAME   Exe: $exe   LaunchOptions: ${launch:-（none）}"
    log_info "Steam config dir(s): ${dirs[*]}"
    if [[ "$ASSUME_YES" != 1 ]] && ! is_dry_run; then
        ask_yes_no "Add this shortcut to the above Steam user(s)?" Y || die "aborted by user"
    fi

    local d vdf rc=0
    for d in "${dirs[@]}"; do
        vdf="$d/shortcuts.vdf"
        [[ -f "$vdf" ]] && backup_file "$vdf"
        if is_dry_run; then
            python3 "$VDF_TOOL" add --vdf "$vdf" --name "$APP_NAME" --exe "$exe" \
                --startdir "\"$startdir\"" --launch "$launch" --flatpak "$flatpak_id" --dry-run \
                || { log_error "dry-run failed for $vdf"; rc=1; }
        else
            if python3 "$VDF_TOOL" add --vdf "$vdf" --name "$APP_NAME" --exe "$exe" \
                --startdir "\"$startdir\"" --launch "$launch" --flatpak "$flatpak_id"; then
                log_ok "updated $vdf"
            else
                log_error "failed to update $vdf"; rc=1
            fi
        fi
    done
    backup_finalize

    log_step "Summary"
    cat <<EOF
  Shortcut       : $APP_NAME
  Steam users    : ${#dirs[@]}
  Backup         : ${PBC_BACKUP_DIR:-（none）}
  Next           : restart Steam; in Game Mode the shortcut appears in your library.
EOF
    is_dry_run && printf '\n%sThis was a DRY RUN — Steam config was not changed.%s\n' "$C_YELLOW" "$C_RESET"
    return $rc
}

main "$@"
