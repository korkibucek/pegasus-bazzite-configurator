#!/usr/bin/env bash
# prereq.sh — prerequisite checks. Each check logs a pass/warn/fail and the
# aggregate is exposed via PBC_PREREQ_FATAL (count of hard failures).

: "${PBC_PREREQ_FATAL:=0}"
: "${PBC_MIN_FREE_KIB:=2097152}"   # 2 GiB default minimum free space

_prereq_fail() { PBC_PREREQ_FATAL=$((PBC_PREREQ_FATAL + 1)); log_error "$@"; }

# check_network — best-effort connectivity test. A warning, never fatal, since
# the user may be pre-seeding config offline with --dry-run.
check_network() {
    local host="${1:-flathub.org}"
    if have curl && curl -fsS --max-time 8 -o /dev/null "https://$host" 2>/dev/null; then
        log_ok "network: reachable ($host)"
    elif have ping && ping -c1 -W3 "$host" >/dev/null 2>&1; then
        log_ok "network: reachable ($host, icmp)"
    else
        log_warn "network: could not confirm connectivity to $host — installs may fail"
    fi
}

# check_git — git is used for documentation workflows and is generally present;
# warn only.
check_git() {
    if have git; then log_ok "git: $(git --version 2>/dev/null)"; else log_warn "git: not found (optional)"; fi
}

# check_flatpak — the core dependency. On Bazzite flatpak ships by default. If
# missing we warn loudly (and it becomes fatal only when an install is actually
# attempted, handled by the install layer).
check_flatpak() {
    if ! have flatpak; then
        log_warn "flatpak: NOT found — required to install Pegasus and emulators on Bazzite"
        PBC_FLATPAK_OK=0
        return 0
    fi
    PBC_FLATPAK_OK=1
    log_ok "flatpak: $(flatpak --version 2>/dev/null)"
    # Is the Flathub remote configured (at user or system scope)?
    if flatpak remotes --columns=name 2>/dev/null | grep -qiw flathub; then
        PBC_FLATHUB_OK=1
        log_ok "flatpak: flathub remote present"
    else
        PBC_FLATHUB_OK=0
        log_warn "flatpak: flathub remote not found — will add it at --user scope when installing"
    fi
}

# check_disk_space PATH — ensures at least PBC_MIN_FREE_KIB available on the
# filesystem backing PATH (or its nearest existing parent).
check_disk_space() {
    local target="${1:-$HOME}"
    local probe="$target"
    while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname -- "$probe")"; done
    local avail
    avail="$(df -Pk -- "$probe" 2>/dev/null | awk 'NR==2{print $4}')"
    if [[ -z "$avail" ]]; then
        log_warn "disk: could not determine free space for $probe"
        return 0
    fi
    if (( avail < PBC_MIN_FREE_KIB )); then
        log_warn "disk: only $(human_kib "$avail") free at $probe (recommended >= $(human_kib "$PBC_MIN_FREE_KIB")). Emulators are large."
    else
        log_ok "disk: $(human_kib "$avail") free at $probe"
    fi
}

# check_writable PATH — verifies we can create/write under PATH (or its nearest
# existing parent). Fatal: we cannot deploy without it.
check_writable() {
    local target="$1"
    local probe="$target"
    while [[ ! -e "$probe" && "$probe" != "/" ]]; do probe="$(dirname -- "$probe")"; done
    if [[ -w "$probe" ]]; then
        log_ok "write access: OK ($probe)"
    else
        _prereq_fail "write access: cannot write to $probe — choose a path under your home directory"
    fi
}

# check_not_root — we should not run as root; system mutation is avoided by
# design. Warn (not fatal) so power users can override deliberately.
check_not_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        log_warn "running as root: this tool installs at --user scope and writes to \$HOME; run as your normal user"
    else
        log_ok "user: running as $(id -un) (non-root, correct)"
    fi
}

# check_existing_pegasus — report current install state (informational).
check_existing_pegasus() {
    PBC_PEGASUS_FLATPAK=0; PBC_PEGASUS_NATIVE=0; PBC_PEGASUS_APPIMAGE=0
    if have flatpak && flatpak info "$PEGASUS_FLATPAK_ID" >/dev/null 2>&1; then
        PBC_PEGASUS_FLATPAK=1; log_info "pegasus: already installed (flatpak)"
    fi
    if have pegasus-fe || have pegasus; then PBC_PEGASUS_NATIVE=1; log_info "pegasus: native binary on PATH"; fi
    if compgen -G "$HOME/Applications/*egasus*.AppImage" >/dev/null 2>&1 \
       || compgen -G "$HOME/.local/bin/*egasus*.AppImage" >/dev/null 2>&1; then
        PBC_PEGASUS_APPIMAGE=1; log_info "pegasus: AppImage present"
    fi
    if (( PBC_PEGASUS_FLATPAK + PBC_PEGASUS_NATIVE + PBC_PEGASUS_APPIMAGE == 0 )); then
        log_info "pegasus: not currently installed"
    fi
}

# run_all_prereqs ROM_ROOT — orchestrates the standard set.
run_all_prereqs() {
    local rom_root="$1"
    log_step "Checking prerequisites"
    check_not_root
    check_network ""
    check_git
    check_flatpak
    check_disk_space "$rom_root"
    check_writable "$rom_root"
    check_existing_pegasus
    if (( PBC_PREREQ_FATAL > 0 )); then
        log_error "$PBC_PREREQ_FATAL fatal prerequisite problem(s) found"
        return 1
    fi
    log_ok "prerequisite checks complete"
    return 0
}
