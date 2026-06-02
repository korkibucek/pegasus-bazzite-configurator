#!/usr/bin/env bash
# install-cores.sh — OPT-IN helper that downloads the libretro cores your
# selected RetroArch systems need, removing the manual "Online Updater > Core
# Downloader" step.
#
# SECURITY / TRUST: cores are fetched from the OFFICIAL libretro buildbot over
# HTTPS only (host pinned in lib/emulators.sh). Each download is validated as a
# real ZIP before extraction and is never executed. There are no per-core
# published checksums to pin; the trust boundary is "the libretro buildbot over
# TLS". This is third-party binary content — run it only if you accept that.
# Existing cores are never overwritten unless --force (and are backed up first).
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
OPT_FORCE=0
usage() {
    cat <<EOF
Usage: scripts/install-cores.sh [--config FILE] [--force] [--dry-run] [-y] [-v]

Download the libretro cores required by your selected RetroArch systems from the
official libretro buildbot into RetroArch's Flatpak cores directory.

  --config FILE   Same config you deployed with (determines the systems/cores).
  --force         Re-download and overwrite existing cores (backed up first).
  --dry-run       List the cores and URLs; download nothing.
  -y, --yes       Do not prompt for confirmation.
  -v, --verbose   Verbose output.
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        --force)     OPT_FORCE=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

trap 'log_error "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"; exit 1' ERR

# collect_cores — echo the unique libretro core names needed by the resolved
# RetroArch systems (honouring per-system emulator overrides).
collect_cores() {
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

# fetch_core CORE — download + validate + extract one core. Returns non-zero on
# failure (non-fatal to the overall run).
fetch_core() {
    local core="$1" dir="$2"
    local target="$dir/${core}_libretro.so"
    local url; url="$(ra_core_url "$core")"

    if [[ -f "$target" && "$OPT_FORCE" != 1 ]]; then
        log_ok "${core}: already installed — skipping (use --force to replace)"
        return 0
    fi
    if is_dry_run; then
        printf '%s[dry-run]%s fetch %s -> %s\n' "$C_DIM" "$C_RESET" "$url" "$target"
        return 0
    fi

    local tmp; tmp="$(mktemp -d)"; local zip="$tmp/core.zip"
    # HTTPS only; the host is pinned in ra_core_url.
    if ! curl -fL --proto '=https' --tlsv1.2 --max-time 120 -o "$zip" "$url"; then
        log_error "${core}: download failed ($url)"; rm -rf "$tmp"; return 1
    fi
    # Validate it is a real zip BEFORE extracting; never execute the payload.
    if ! _is_zip "$zip"; then
        log_error "${core}: downloaded file is not a valid zip — refusing to extract"; rm -rf "$tmp"; return 1
    fi
    [[ -f "$target" ]] && backup_file "$target"
    if _unzip_to "$zip" "$dir"; then
        log_ok "${core}: installed"
    else
        log_error "${core}: extraction failed"; rm -rf "$tmp"; return 1
    fi
    rm -rf "$tmp"
}

_is_zip() {
    if have unzip; then unzip -tqq "$1" >/dev/null 2>&1; return; fi
    if have python3; then python3 -c 'import sys,zipfile; sys.exit(0 if zipfile.is_zipfile(sys.argv[1]) else 1)' "$1"; return; fi
    # Last resort: check the PK magic bytes.
    [[ "$(head -c2 "$1")" == "PK" ]]
}
_unzip_to() {
    if have unzip; then unzip -o "$1" -d "$2" >/dev/null; return; fi
    python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$1" "$2"
}

main() {
    config_set_defaults
    [[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
    detect_all
    log_init ""
    is_dry_run && log_warn "DRY-RUN MODE — nothing will be downloaded"

    if [[ " $CFG_EMULATORS " != *" retroarch "* ]] && [[ "$CFG_SYSTEMS" == auto ]]; then
        log_warn "RetroArch is not in your selected emulators; no cores to fetch"
        exit 0
    fi

    local cores; mapfile -t cores < <(collect_cores)
    if [[ ${#cores[@]} -eq 0 ]]; then
        log_warn "no RetroArch cores required by the resolved systems"
        exit 0
    fi

    log_step "RetroArch cores to install (${#cores[@]})"
    printf '  %s\n' "${cores[@]}"
    log_warn "These are third-party binaries from the official libretro buildbot (${RA_CORE_BUILDBOT})."
    if [[ "$ASSUME_YES" != 1 ]] && ! is_dry_run; then
        ask_yes_no "Download these cores now?" Y || die "aborted by user"
    fi

    local dir; dir="$(ra_core_dir)"
    run_cmd mkdir -p -- "$dir"
    if ! have curl && ! is_dry_run; then die "curl is required to download cores"; fi

    local core ok=0 failed=0
    for core in "${cores[@]}"; do
        if fetch_core "$core" "$dir"; then ok=$((ok+1)); else failed=$((failed+1)); fi
    done
    backup_finalize

    log_step "Core install summary"
    printf '  installed/ok : %d\n  failed       : %d\n  cores dir    : %s\n' "$ok" "$failed" "$dir"
    is_dry_run && printf '\n%sThis was a DRY RUN — nothing was downloaded.%s\n' "$C_YELLOW" "$C_RESET"
    [[ "$failed" -eq 0 ]]
}

main "$@"
