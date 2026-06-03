#!/usr/bin/env bash
# validate.sh — post-deployment health checker. Produces a PASS/FAIL summary
# and exits non-zero if any hard check fails. Re-uses the same libraries and
# (optionally) the same config file as deploy.sh so expectations match.
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
EXPECT_BACKUP=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        --expect-backup) EXPECT_BACKUP=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)
            echo "Usage: scripts/validate.sh [--config FILE] [--expect-backup] [-v]"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  %s[PASS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  %s[FAIL]%s %s\n' "$C_RED"   "$C_RESET" "$*"; }
warn() { WARN=$((WARN+1)); printf '  %s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }

# flatpak_can_access ID PATH -> 0 if the sandbox can read PATH.
flatpak_can_access() {
    local id="$1" path="$2" perms toks t
    have flatpak || return 1
    perms="$(flatpak info --show-permissions "$id" 2>/dev/null || true)$(printf '\n')$(flatpak override --user --show "$id" 2>/dev/null || true)"
    # Extract filesystem tokens from any 'filesystems=' line(s).
    toks="$(grep -i '^filesystems=' <<<"$perms" 2>/dev/null | sed -E 's/^filesystems=//I' | tr ';,' '\n')"
    while IFS= read -r t; do
        t="$(trim "$t")"; [[ -n "$t" ]] || continue
        case "$t" in
            host|host:rw|host-os|home|home:rw|/|/:rw) return 0 ;;
        esac
        # Strip a :rw/:ro/:create suffix, then check if it is a prefix of PATH.
        local p="${t%%:*}"
        p="${p/#\~/$HOME}"
        [[ -n "$p" && "$path" == "$p"* ]] && return 0
    done <<<"$toks"
    return 1
}

main() {
    config_set_defaults
    [[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
    detect_all
    pegasus_resolve_config_dir

    printf '%s== Pegasus-Bazzite-Configurator validation ==%s\n' "$C_BOLD" "$C_RESET"
    printf 'OS: %s\n\n' "$(os_summary_line)"

    # 1) Pegasus present/launchable
    printf '%sPegasus%s\n' "$C_BOLD" "$C_RESET"
    if flatpak info "$PEGASUS_FLATPAK_ID" >/dev/null 2>&1; then
        ok "Pegasus installed (flatpak): $PEGASUS_FLATPAK_ID"
        if flatpak_can_access "$PEGASUS_FLATPAK_ID" "$CFG_ROM_ROOT"; then
            ok "Pegasus can access ROM root ($CFG_ROM_ROOT)"
        else
            bad "Pegasus lacks filesystem access to $CFG_ROM_ROOT — run: flatpak override --user $PEGASUS_FLATPAK_ID --filesystem=\"$CFG_ROM_ROOT\""
        fi
    elif have pegasus-fe || compgen -G "$HOME"/Applications/*egasus*.AppImage >/dev/null 2>&1; then
        ok "Pegasus present (native/AppImage)"
    else
        bad "Pegasus not found (expected flatpak $PEGASUS_FLATPAK_ID)"
    fi

    # 2) Config files
    printf '\n%sPegasus config%s\n' "$C_BOLD" "$C_RESET"
    local gd="$PEGASUS_CONFIG_DIR/game_dirs.txt"
    if [[ -f "$gd" ]]; then
        ok "game_dirs.txt present ($gd)"
    else
        warn "game_dirs.txt not found at $gd (run deploy.sh, or Pegasus has not been launched yet)"
    fi

    # 3) Emulators selected in config
    printf '\n%sEmulators%s\n' "$C_BOLD" "$C_RESET"
    local k
    for k in $CFG_EMULATORS; do
        emu_exists "$k" || { warn "unknown emulator key '$k' in config"; continue; }
        if emu_installed "$k"; then
            ok "${EMU_NAME[$k]} installed"
            if emu_is_appimage "$k"; then
                ok "  ${k}: AppImage (runs on host, no sandbox — reads ROMs directly)"
            elif flatpak_can_access "${EMU_ID[$k]}" "$CFG_ROM_ROOT"; then
                ok "  ${k}: sandbox can access ROM root"
            else
                bad "  ${k}: NO sandbox access to $CFG_ROM_ROOT — run: flatpak override --user ${EMU_ID[$k]} --filesystem=\"$CFG_ROM_ROOT\""
            fi
        elif emu_is_appimage "$k"; then
            bad "${EMU_NAME[$k]} not installed (AppImage missing at $(emu_appimage_path "$k"))"
        else
            bad "${EMU_NAME[$k]} not installed (${EMU_ID[$k]})"
        fi
    done

    # 3b) BIOS / firmware preflight (WARN only — we never provide these files).
    printf '\n%sBIOS / firmware%s\n' "$C_BOLD" "$C_RESET"
    local need_bios=0 bdir
    for k in $CFG_EMULATORS; do
        emu_exists "$k" || continue
        bdir="$(emu_bios_dir "$k")" || continue
        need_bios=1
        if [[ -d "$bdir" ]] && find "$bdir" -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
            ok "${k}: BIOS/firmware present ($bdir)"
        else
            warn "${k}: no BIOS/firmware in $bdir — add ${EMU_BIOS_NOTE[$k]} (legally obtained dumps; none are provided)"
        fi
    done
    [[ "$need_bios" == 0 ]] && ok "no selected emulator requires BIOS/firmware"

    # 4) ROM root + per-system metadata
    printf '\n%sROM paths & metadata%s\n' "$C_BOLD" "$C_RESET"
    if [[ -d "$CFG_ROM_ROOT" ]]; then ok "ROM root exists: $CFG_ROM_ROOT"; else bad "ROM root missing: $CFG_ROM_ROOT"; fi
    local systems; mapfile -t systems < <(pegasus_resolve_systems)
    if [[ ${#systems[@]} -eq 0 ]]; then
        warn "no systems resolved from config (emulators: $CFG_EMULATORS)"
    fi
    local sn dir meta
    for sn in "${systems[@]}"; do
        dir="$CFG_ROM_ROOT/$(resolve_system_dirname "$sn" "$(_sys_field "$sn" SYS_DIRNAME)")"
        meta="$dir/metadata.pegasus.txt"
        if [[ -f "$meta" ]]; then
            validate_metadata_file "$sn" "$meta"
        else
            warn "$sn: metadata not found ($meta)"
        fi
    done

    # 4b) RetroArch cores (WARN only) — missing cores are the #1 RetroArch
    # failure ("Failed to load core"). Only meaningful when RetroArch is
    # installed; otherwise the earlier 'not installed' check already flagged it.
    if emu_installed retroarch; then
        printf '\n%sRetroArch cores%s\n' "$C_BOLD" "$C_RESET"
        local cdir; cdir="$(ra_core_dir)"
        local ra_count=0 def_emu def_core pair emu core so
        for sn in "${systems[@]}"; do
            def_emu="$(_sys_field "$sn" SYS_EMULATOR)"
            def_core="$(_sys_field "$sn" SYS_RA_CORE)"
            pair="$(resolve_system_emulator "$sn" "$def_emu" "$def_core")"
            emu="${pair%%$'\t'*}"; core="${pair#*$'\t'}"
            [[ "$emu" == retroarch && -n "$core" ]] || continue
            ra_count=$((ra_count+1))
            so="$(ra_core_file "$core")"
            if [[ -f "$so" ]]; then
                ok "${sn}: core ${core} present"
            else
                warn "${sn}: core ${core} missing ($so) — run scripts/install-cores.sh or RetroArch > Online Updater > Core Downloader"
            fi
        done
        [[ "$ra_count" == 0 ]] && ok "no RetroArch systems configured"
    fi

    # 5) Backups
    printf '\n%sBackups%s\n' "$C_BOLD" "$C_RESET"
    local latest; latest="$(backup_latest)"
    if [[ "$EXPECT_BACKUP" == 1 ]]; then
        if [[ -n "$latest" ]]; then ok "backup present: $latest"; else bad "expected a backup but none found under $(backup_root)"; fi
    else
        if [[ -n "$latest" ]]; then ok "most recent backup: $latest"; else warn "no backups found (none expected on a first/clean run)"; fi
    fi

    # --- summary ---
    printf '\n%s== Result: %d passed, %d warnings, %d failed ==%s\n' "$C_BOLD" "$PASS" "$WARN" "$FAIL" "$C_RESET"
    (( FAIL == 0 )) && { printf '%sVALIDATION PASSED%s\n' "$C_GREEN" "$C_RESET"; return 0; }
    printf '%sVALIDATION FAILED%s\n' "$C_RED" "$C_RESET"; return 1
}

# validate_metadata_file SHORTNAME PATH — structural checks on a metadata file.
validate_metadata_file() {
    local sn="$1" meta="$2"
    local has_collection=0 has_launch=0 has_ext=0 launch_line=""
    local line
    while IFS= read -r line; do
        case "$line" in
            collection:*) has_collection=1 ;;
            launch:*)     has_launch=1; launch_line="${line#launch:}" ;;
            extensions:*|extension:*) has_ext=1 ;;
        esac
    done <"$meta"
    if (( has_collection && has_launch && has_ext )); then
        ok "$sn: metadata parses (collection/launch/extensions present)"
    else
        bad "$sn: metadata missing required keys (collection=$has_collection launch=$has_launch ext=$has_ext)"
    fi
    # Balanced double-quotes in the launch line (catches obvious quoting errors).
    local q="${launch_line//[^\"]/}"
    if (( ${#q} % 2 != 0 )); then
        bad "$sn: unbalanced quotes in launch line: $launch_line"
    fi
}

main "$@"
