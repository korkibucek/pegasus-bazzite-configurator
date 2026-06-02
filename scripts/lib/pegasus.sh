#!/usr/bin/env bash
# pegasus.sh — install Pegasus Frontend and generate its configuration and
# per-system metadata.
#
# INSTALL ROUTE (issue #4): Flatpak from Flathub is the primary, most robust
# route on an atomic OS — reversible, no reboot, no base-image mutation. An
# AppImage fallback is documented (we do NOT auto-download arbitrary binaries).
#
# CRITICAL CROSS-SANDBOX DETAIL: when Pegasus itself is a Flatpak AND the
# emulators are Flatpaks, Pegasus cannot simply run `flatpak run ...` from
# inside its own sandbox. It must call out to the host via `flatpak-spawn
# --host`, which requires the org.freedesktop.Flatpak talk-name. We add that
# permission and prefix every launch line accordingly (LAUNCH_PREFIX).

: "${PBC_SYSTEMS_DIR:=}"        # set by deploy.sh to config/systems
LAUNCH_PREFIX=""                # prepended to every generated launch line
PBC_PEGASUS_IS_FLATPAK=0

# ---------------------------------------------------------------------------
# Config-dir resolution
# ---------------------------------------------------------------------------
pegasus_resolve_config_dir() {
    if [[ "$CFG_PEGASUS_CONFIG_DIR" != auto && -n "$CFG_PEGASUS_CONFIG_DIR" ]]; then
        PEGASUS_CONFIG_DIR="$CFG_PEGASUS_CONFIG_DIR"
    elif [[ "$CFG_PEGASUS_INSTALL" == flatpak ]] || flatpak info "$PEGASUS_FLATPAK_ID" >/dev/null 2>&1; then
        # Flatpak Pegasus keeps its config inside its per-app sandbox dir.
        PEGASUS_CONFIG_DIR="$HOME/.var/app/$PEGASUS_FLATPAK_ID/config/pegasus-frontend"
    else
        PEGASUS_CONFIG_DIR="$HOME/.config/pegasus-frontend"
    fi
    log_debug "pegasus config dir: $PEGASUS_CONFIG_DIR"
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
pegasus_install() {
    log_step "Installing Pegasus Frontend"
    case "$CFG_PEGASUS_INSTALL" in
        skip)
            log_info "pegasus_install=skip — not installing Pegasus"
            ;;
        appimage)
            # We never auto-download an unverified binary. Provide clear,
            # actionable manual steps and flag it as an outstanding action.
            log_warn "AppImage mode selected — manual step required (no auto-download for safety)"
            PBC_OUTSTANDING+=("Download the Pegasus AppImage from https://pegasus-frontend.org/ (or GitHub releases), 'chmod +x' it, and place it in ~/Applications. See docs/EMULATOR_SUPPORT.md.")
            PBC_PEGASUS_IS_FLATPAK=0
            ;;
        flatpak|*)
            if flatpak info "$PEGASUS_FLATPAK_ID" >/dev/null 2>&1; then
                log_ok "Pegasus already installed (flatpak) — skipping install"
                PBC_PEGASUS_IS_FLATPAK=1
            else
                ensure_flathub || { log_error "cannot install Pegasus without Flathub"; return 1; }
                log_info "Installing Pegasus Frontend ($PEGASUS_FLATPAK_ID)"
                if run_cmd flatpak install --user --noninteractive --assumeyes flathub "$PEGASUS_FLATPAK_ID"; then
                    PBC_PEGASUS_IS_FLATPAK=1
                    PBC_PEGASUS_INSTALLED=1
                else
                    log_error "Pegasus Flatpak install failed"
                    return 1
                fi
            fi
            ;;
    esac

    # Decide the launch prefix and grant cross-sandbox + ROM access.
    if [[ "$PBC_PEGASUS_IS_FLATPAK" == 1 ]]; then
        LAUNCH_PREFIX="flatpak-spawn --host "
        log_info "Pegasus is a Flatpak → launch commands use 'flatpak-spawn --host'"
        # Allow Pegasus to spawn host processes (i.e. flatpak run <emulator>).
        run_cmd flatpak override --user "$PEGASUS_FLATPAK_ID" --talk-name=org.freedesktop.Flatpak
        # Allow Pegasus to read ROMs/metadata.
        # shellcheck disable=SC2086  # intentional split of the extra-paths list
        pegasus_grant_paths "$CFG_ROM_ROOT" $CFG_EXTRA_ROM_PATHS
    else
        LAUNCH_PREFIX=""
    fi
}

# pegasus_grant_paths PATH... — grant the Pegasus Flatpak filesystem access.
pegasus_grant_paths() {
    [[ "$PBC_PEGASUS_IS_FLATPAK" == 1 ]] || return 0
    local p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        run_cmd flatpak override --user "$PEGASUS_FLATPAK_ID" "--filesystem=${p}"
    done
}

# ---------------------------------------------------------------------------
# System catalog
# ---------------------------------------------------------------------------

# pegasus_resolve_systems — echo the list of system shortnames to generate.
# CFG_SYSTEMS=auto => every catalog system whose default emulator was selected.
pegasus_resolve_systems() {
    local out=()
    if [[ "$CFG_SYSTEMS" != auto && -n "$CFG_SYSTEMS" ]]; then
        local s
        for s in $CFG_SYSTEMS; do
            if [[ -r "$PBC_SYSTEMS_DIR/$s.conf" ]]; then
                out+=("$s")
            else
                log_warn "system '$s' has no definition in $PBC_SYSTEMS_DIR"
            fi
        done
    else
        local f sn emu
        for f in "$PBC_SYSTEMS_DIR"/*.conf; do
            [[ -r "$f" ]] || continue
            # shellcheck disable=SC1090  # data file path is dynamic by design
            ( sn=""; emu=""; . "$f"; printf '%s\t%s\n' "$SYS_SHORTNAME" "$SYS_EMULATOR" )
        done | while IFS=$'\t' read -r sn emu; do
            # Include the system only if its emulator is in the selected set.
            if [[ " $CFG_EMULATORS " == *" $emu "* ]]; then printf '%s\n' "$sn"; fi
        done
        return 0
    fi
    printf '%s\n' "${out[@]}"
}

# build_launch_line EMULATOR RA_CORE — produce the final Pegasus launch line,
# substituting the RetroArch core path and prefixing for cross-sandbox launch.
# EMU_LAUNCH is the controller-friendly (fullscreen/batch) form; when
# controller_friendly=no and a windowed variant exists, use that instead.
build_launch_line() {
    local emu="$1" core="$2" tmpl="${EMU_LAUNCH[$1]:-}"
    if ! cfg_is_yes "$CFG_CONTROLLER_FRIENDLY" && [[ -n "${EMU_LAUNCH_WINDOWED[$1]:-}" ]]; then
        tmpl="${EMU_LAUNCH_WINDOWED[$1]}"
    fi
    [[ -n "$tmpl" ]] || { log_error "no launch template for emulator '$emu'"; return 1; }
    if [[ "$emu" == retroarch ]]; then
        local cp="$HOME/.var/app/${EMU_ID[retroarch]}/config/retroarch/cores/${core}_libretro.so"
        tmpl="${tmpl//\{CORE_PATH\}/$cp}"
    fi
    printf '%s%s' "$LAUNCH_PREFIX" "$tmpl"
}

# ---------------------------------------------------------------------------
# Metadata + settings generation
# ---------------------------------------------------------------------------

# pegasus_write_game_dirs DIR... — register each system directory with Pegasus
# by writing game_dirs.txt (one absolute path per line). This is the reliable
# pattern: each registered dir contains its own metadata.pegasus.txt.
pegasus_write_game_dirs() {
    local gd="$PEGASUS_CONFIG_DIR/game_dirs.txt"
    backup_file "$gd"
    local content="" d
    # Preserve any pre-existing entries that are not ours, then add ours.
    if [[ -f "$gd" ]]; then content="$(cat "$gd")"; fi
    for d in "$@"; do
        [[ -n "$d" ]] || continue
        if ! grep -qxF "$d" <<<"$content" 2>/dev/null; then
            content+="${content:+$'\n'}$d"
        fi
    done
    printf '%s\n' "$content" | write_file "$gd"
    log_ok "registered ${#@} game directories in $gd"
}

# pegasus_generate — main generation entrypoint. Creates ROM subdirs, metadata,
# example collections, and registers game dirs.
pegasus_generate() {
    log_step "Generating Pegasus configuration"
    pegasus_resolve_config_dir

    # ROM root.
    if [[ ! -d "$CFG_ROM_ROOT" ]]; then
        if cfg_is_yes "$CFG_CREATE_ROM_DIR"; then
            run_cmd mkdir -p -- "$CFG_ROM_ROOT" || { log_error "cannot create ROM root $CFG_ROM_ROOT"; return 1; }
            log_ok "created ROM root: $CFG_ROM_ROOT"
        else
            log_error "ROM root $CFG_ROM_ROOT does not exist and create_rom_dir=no"
            return 1
        fi
    fi

    local systems; mapfile -t systems < <(pegasus_resolve_systems)
    if [[ ${#systems[@]} -eq 0 ]]; then
        log_warn "no systems matched the selected emulators — nothing to generate"
        return 0
    fi
    log_info "Generating ${#systems[@]} system(s): ${systems[*]}"

    local gamedirs=() sn
    for sn in "${systems[@]}"; do
        pegasus_generate_system "$sn" && gamedirs+=("$CFG_ROM_ROOT/$(_sys_field "$sn" SYS_DIRNAME)")
    done

    pegasus_write_game_dirs "${gamedirs[@]}"
}

# _sys_field SHORTNAME FIELD — read one field from a system conf in a subshell.
_sys_field() {
    local sn="$1" field="$2"
    # shellcheck disable=SC1090  # data file path is dynamic by design
    ( . "$PBC_SYSTEMS_DIR/$sn.conf"; printf '%s' "${!field}" )
}

# pegasus_generate_system SHORTNAME — write one system's directory + metadata.
pegasus_generate_system() {
    local sn="$1" conf="$PBC_SYSTEMS_DIR/$1.conf"
    [[ -r "$conf" ]] || { log_warn "missing conf for $sn"; return 1; }
    # shellcheck disable=SC1090
    local SYS_SHORTNAME SYS_NAME SYS_DIRNAME SYS_EMULATOR SYS_EXTENSIONS SYS_RA_CORE
    # shellcheck disable=SC1090  # data file path is dynamic by design
    . "$conf"
    local dir="$CFG_ROM_ROOT/$SYS_DIRNAME"
    local meta="$dir/metadata.pegasus.txt"

    # Skip systems whose emulator was not selected (defensive; resolve already filters in auto mode).
    if [[ " $CFG_EMULATORS " != *" $SYS_EMULATOR "* ]]; then
        log_debug "skip $sn: emulator $SYS_EMULATOR not selected"
        return 1
    fi

    run_cmd mkdir -p -- "$dir" || { log_error "cannot create $dir"; return 1; }

    # Respect install-missing vs force.
    if [[ -f "$meta" && "$CFG_MODE" != force ]]; then
        log_info "$sn: metadata exists, mode=install-missing → leaving as-is"
        PBC_SYSTEMS_SKIPPED+=("$sn")
        return 0
    fi
    backup_file "$meta"

    local launch; launch="$(build_launch_line "$SYS_EMULATOR" "$SYS_RA_CORE")" || return 1

    # Build metadata content. {file.path} etc. are Pegasus variables and are
    # intentionally left literal for Pegasus to expand at launch time.
    {
        printf '# Generated by pegasus-bazzite-configurator on %s\n' "$(_iso_now)"
        printf '# System: %s   Emulator: %s\n' "$SYS_NAME" "$SYS_EMULATOR"
        [[ "$SYS_EMULATOR" == retroarch ]] && printf '# RetroArch core: %s_libretro (install via RetroArch > Online Updater)\n' "$SYS_RA_CORE"
        printf '# Edit freely. Re-running deploy.sh backs this up before any overwrite.\n\n'
        printf 'collection: %s\n' "$SYS_NAME"
        printf 'shortname: %s\n' "$SYS_SHORTNAME"
        printf 'extensions: %s\n' "$SYS_EXTENSIONS"
        printf 'launch: %s\n' "$launch"
        printf '\n# Artwork/media: place assets under %s/<rom-basename>/\n' "$CFG_MEDIA_DIRNAME"
        printf '#   e.g. boxFront.png, screenshot.png, logo.png, video.mp4\n'
    } | write_file "$meta"
    log_ok "$sn: wrote $meta"
    PBC_SYSTEMS_WRITTEN+=("$sn")

    # Media directory + add-ROMs helper / example collection.
    run_cmd mkdir -p -- "$dir/$CFG_MEDIA_DIRNAME"
    if cfg_is_yes "$CFG_EXAMPLE_COLLECTIONS"; then
        printf 'Place %s ROMs here.\nSupported extensions: %s\nLaunches with: %s\n\nThis collection appears in Pegasus even while empty.\nNo BIOS/ROM/firmware files are provided — add your own legally obtained dumps.\n' \
            "$SYS_NAME" "$SYS_EXTENSIONS" "$SYS_EMULATOR" | write_file "$dir/HOW_TO_ADD_ROMS.txt"
    fi
    return 0
}
