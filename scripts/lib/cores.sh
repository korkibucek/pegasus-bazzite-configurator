#!/usr/bin/env bash
# cores.sh — download the libretro cores required by the configured RetroArch
# systems. Shared by deploy.sh (when install_cores=yes) and install-cores.sh.
#
# SECURITY/TRUST: cores are fetched from the OFFICIAL libretro buildbot over
# HTTPS only (host pinned in emulators.sh). Each download is validated as a real
# ZIP before extraction and is never executed. There are no per-core published
# checksums to pin; the trust boundary is "the libretro buildbot over TLS".
# Existing cores are kept unless force=1 (and are backed up first).
#
# Requires functions from: common.sh, emulators.sh (ra_core_url/ra_core_dir),
# pegasus.sh (pegasus_resolve_systems/resolve_system_emulator/_sys_field),
# backup.sh (backup_file).

# cores_collect — unique libretro core names needed by the resolved RetroArch
# systems (honouring per-system overrides). One per line on stdout.
cores_collect() {
    local sn def_emu def_core pair emu core
    local systems; mapfile -t systems < <(pegasus_resolve_systems)
    declare -A seen=()
    for sn in "${systems[@]}"; do
        def_emu="$(_sys_field "$sn" SYS_EMULATOR)"
        def_core="$(_sys_field "$sn" SYS_RA_CORE)"
        pair="$(resolve_system_emulator "$sn" "$def_emu" "$def_core")"
        emu="${pair%%$'\t'*}"; core="${pair#*$'\t'}"
        [[ "$emu" == retroarch && -n "$core" ]] || continue
        [[ -n "${seen[$core]:-}" ]] && continue
        seen[$core]=1
        printf '%s\n' "$core"
    done
}

_cores_is_zip() {
    if have unzip; then unzip -tqq "$1" >/dev/null 2>&1; return; fi
    if have python3; then python3 -c 'import sys,zipfile; sys.exit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)' "$1"; return; fi
    [[ "$(head -c2 "$1")" == "PK" ]]
}
_cores_unzip_to() {
    if have unzip; then unzip -o "$1" -d "$2" >/dev/null; return; fi
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
}

# cores_fetch_one CORE DIR [FORCE] — download + validate + extract one core.
# Per-core failures are non-fatal (logged as WARN) so they never abort a deploy.
cores_fetch_one() {
    local core="$1" dir="$2" force="${3:-0}"
    local target="$dir/${core}_libretro.so"
    local url; url="$(ra_core_url "$core")"

    if [[ -f "$target" && "$force" != 1 ]]; then
        log_ok "${core}: already installed — skipping (force to replace)"
        return 0
    fi
    if is_dry_run; then
        printf '%s[dry-run]%s fetch %s -> %s\n' "$C_DIM" "$C_RESET" "$url" "$target"
        return 0
    fi
    local tmp; tmp="$(mktemp -d)"; local zip="$tmp/core.zip"
    if ! curl -fL --proto '=https' --tlsv1.2 --max-time 120 -o "$zip" "$url"; then
        log_warn "${core}: download failed ($url)"; rm -rf "$tmp"; return 1
    fi
    if ! _cores_is_zip "$zip"; then
        log_warn "${core}: downloaded file is not a valid zip — refusing to extract"; rm -rf "$tmp"; return 1
    fi
    [[ -f "$target" ]] && backup_file "$target"
    if _cores_unzip_to "$zip" "$dir"; then
        log_ok "${core}: installed"
    else
        log_warn "${core}: extraction failed"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
}

# cores_install [FORCE] — gather the needed cores and install them. Sets
# PBC_CORES_OK / PBC_CORES_FAILED. Returns non-zero only if a core failed to
# download (callers decide severity — deploy treats it as a warning).
cores_install() {
    local force="${1:-0}"
    declare -ga PBC_CORES_OK=() PBC_CORES_FAILED=()
    local cores; mapfile -t cores < <(cores_collect)
    if [[ ${#cores[@]} -eq 0 ]]; then
        log_info "no RetroArch cores required by the configured systems"
        return 0
    fi
    log_step "Installing RetroArch cores (${#cores[@]})"
    log_info "from the official libretro buildbot: ${RA_CORE_BUILDBOT}"
    if ! have curl && ! is_dry_run; then
        log_warn "curl not available — cannot download cores; install them via RetroArch > Online Updater"
        return 1
    fi
    local dir; dir="$(ra_core_dir)"
    run_cmd mkdir -p -- "$dir"
    local core
    for core in "${cores[@]}"; do
        if cores_fetch_one "$core" "$dir" "$force"; then PBC_CORES_OK+=("$core"); else PBC_CORES_FAILED+=("$core"); fi
    done
    [[ ${#PBC_CORES_FAILED[@]} -eq 0 ]]
}
