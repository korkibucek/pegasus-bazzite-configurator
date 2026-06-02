#!/usr/bin/env bash
# emulators.sh — data-driven emulator catalog + Flatpak install + sandbox
# permission handling.
#
# DESIGN: emulators are installed as Flathub Flatpaks at --user scope. This is
# the most robust, fully reversible route on an immutable/atomic OS — it never
# touches the base image and needs no reboot (unlike rpm-ostree layering).
#
# THE CRITICAL GOTCHA we handle here: a Flatpak emulator runs sandboxed and
# CANNOT read the ROM directory (especially SD cards under /run/media/...)
# unless granted access. We therefore run, for every selected emulator:
#     flatpak override --user <app> --filesystem=<ROM root>
# Without this, Pegasus launches the emulator but the game is "not found".

# Each emulator is described by three parallel associative arrays.
#   EMU_NAME[k]   human name
#   EMU_ID[k]     Flathub application id
#   EMU_LAUNCH[k] the emulator portion of a Pegasus launch line. May contain:
#                   {CORE_PATH}  -> resolved per-system (RetroArch only)
#                   {file.path}, {file.dir}, {file.basename} -> Pegasus vars
#                   (left literal so Pegasus substitutes them at launch time)
#   EMU_NOTE[k]   optional caveat surfaced to the user
declare -gA EMU_NAME EMU_ID EMU_LAUNCH EMU_NOTE

EMU_NAME[retroarch]="RetroArch (multi-system)"
EMU_ID[retroarch]="org.libretro.RetroArch"
EMU_LAUNCH[retroarch]='flatpak run org.libretro.RetroArch -L "{CORE_PATH}" "{file.path}"'
EMU_NOTE[retroarch]="Cores are NOT bundled; install them once via RetroArch > Online Updater > Core Downloader. Each system documents the core it expects."

EMU_NAME[dolphin]="Dolphin (GameCube / Wii)"
EMU_ID[dolphin]="org.DolphinEmu.dolphin-emu"
EMU_LAUNCH[dolphin]='flatpak run org.DolphinEmu.dolphin-emu -b -e "{file.path}"'

EMU_NAME[pcsx2]="PCSX2 (PlayStation 2)"
EMU_ID[pcsx2]="net.pcsx2.PCSX2"
EMU_LAUNCH[pcsx2]='flatpak run net.pcsx2.PCSX2 -batch "{file.path}"'
EMU_NOTE[pcsx2]="Requires a legally dumped PS2 BIOS, configured once in PCSX2 settings."

EMU_NAME[ppsspp]="PPSSPP (PSP)"
EMU_ID[ppsspp]="org.ppsspp.PPSSPP"
EMU_LAUNCH[ppsspp]='flatpak run org.ppsspp.PPSSPP "{file.path}"'

EMU_NAME[duckstation]="DuckStation (PlayStation 1)"
EMU_ID[duckstation]="org.duckstation.DuckStation"
EMU_LAUNCH[duckstation]='flatpak run org.duckstation.DuckStation -batch -fullscreen "{file.path}"'
EMU_NOTE[duckstation]="DuckStation's license/Flathub availability has changed over time; if 'flatpak install' fails, use SwanStation via RetroArch (psx) instead. Requires a legally dumped PS1 BIOS."

EMU_NAME[rpcs3]="RPCS3 (PlayStation 3)"
EMU_ID[rpcs3]="net.rpcs3.RPCS3"
EMU_LAUNCH[rpcs3]='flatpak run net.rpcs3.RPCS3 --no-gui "{file.path}"'
EMU_NOTE[rpcs3]="Requires the PS3 firmware (legally obtained) installed once in RPCS3. Demanding; best on desktop hardware."

EMU_NAME[mame]="MAME (Arcade)"
EMU_ID[mame]="org.mamedev.MAME"
EMU_LAUNCH[mame]='flatpak run org.mamedev.MAME -rompath "{file.dir}" "{file.basename}"'
EMU_NOTE[mame]="MAME launches by ROM short-name and needs matching, version-correct ROM sets."

EMU_NAME[melonds]="melonDS (Nintendo DS)"
EMU_ID[melonds]="net.kuribo64.melonDS"
EMU_LAUNCH[melonds]='flatpak run net.kuribo64.melonDS "{file.path}"'

EMU_NAME[scummvm]="ScummVM (point-and-click adventures)"
EMU_ID[scummvm]="org.scummvm.ScummVM"
EMU_LAUNCH[scummvm]='flatpak run org.scummvm.ScummVM -p "{file.dir}" -f "{file.basename}"'
EMU_NOTE[scummvm]="ScummVM identifies games rather than running raw files. Recommended: create one .scummvm file per game containing its ScummVM game id. See docs/EMULATOR_SUPPORT.md."

# Stable display order for menus/summaries.
EMU_ORDER=(retroarch dolphin pcsx2 ppsspp duckstation rpcs3 mame melonds scummvm)

# emu_exists KEY -> 0 if the key is in the catalog.
emu_exists() { [[ -n "${EMU_ID[$1]:-}" ]]; }

# emu_installed KEY -> 0 if the Flatpak is installed.
emu_installed() {
    have flatpak || return 1
    flatpak info "${EMU_ID[$1]}" >/dev/null 2>&1
}

# ensure_flathub — make sure a flathub remote exists; add at --user scope if not.
ensure_flathub() {
    if ! have flatpak; then
        # In dry-run we are only previewing (and the dev host may lack flatpak);
        # on real Bazzite flatpak is always present. Don't hard-fail a preview.
        if is_dry_run; then
            log_warn "flatpak not present here; on Bazzite it is preinstalled — preview continues"
            return 0
        fi
        log_error "flatpak is required but not installed"
        return 1
    fi
    if flatpak remotes --columns=name 2>/dev/null | grep -qiw flathub; then return 0; fi
    log_info "Adding Flathub remote at --user scope"
    run_cmd flatpak remote-add --user --if-not-exists flathub \
        https://dl.flathub.org/repo/flathub.flatpakrepo
}

# emu_install KEY — install one emulator Flatpak (idempotent).
emu_install() {
    local k="$1" id="${EMU_ID[$1]}"
    if emu_installed "$k"; then
        log_ok "${EMU_NAME[$k]}: already installed — skipping"
        PBC_EMU_SKIPPED+=("$k")
        return 0
    fi
    log_info "Installing ${EMU_NAME[$k]} ($id)"
    [[ -n "${EMU_NOTE[$k]:-}" ]] && log_warn "${k}: ${EMU_NOTE[$k]}"
    if run_cmd flatpak install --user --noninteractive --assumeyes flathub "$id"; then
        PBC_EMU_INSTALLED+=("$k")
    else
        log_error "Failed to install $id (continuing with remaining emulators)"
        PBC_EMU_FAILED+=("$k")
        return 1
    fi
}

# emu_grant_rom_access KEY PATH... — grant the emulator filesystem access to
# each ROM/media path so the sandbox can read games.
emu_grant_rom_access() {
    local k="$1"; shift
    local id="${EMU_ID[$k]}" p
    for p in "$@"; do
        [[ -n "$p" ]] || continue
        log_debug "grant ${k} access to ${p}"
        run_cmd flatpak override --user "$id" "--filesystem=${p}"
    done
}

# emu_install_selected "k1 k2 ..." ROM_ROOT [EXTRA_PATH...] — install all
# selected emulators and grant them ROM access. Aggregate arrays are exported.
emu_install_selected() {
    local list="$1"; shift
    local rom_root="$1"; shift
    local extra=("$@")
    declare -ga PBC_EMU_INSTALLED=() PBC_EMU_SKIPPED=() PBC_EMU_FAILED=()
    [[ -z "${list// }" ]] && { log_warn "no emulators selected"; return 0; }
    ensure_flathub || return 1
    local k
    for k in $list; do
        emu_exists "$k" || { log_warn "unknown emulator '$k' — skipping"; continue; }
        emu_install "$k" || continue
        emu_grant_rom_access "$k" "$rom_root" "${extra[@]}"
    done
}
