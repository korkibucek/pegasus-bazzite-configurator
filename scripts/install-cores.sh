#!/usr/bin/env bash
# install-cores.sh — OPT-IN standalone helper to download the libretro cores
# your selected RetroArch systems need. The same logic runs inside deploy.sh
# when `install_cores: yes` (the default); use this to (re)install cores on
# their own, e.g. with --force.
#
# Cores come from the OFFICIAL libretro buildbot over HTTPS (validated as zips,
# never executed). See scripts/lib/cores.sh for the trust boundary.
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
# shellcheck source=scripts/lib/cores.sh
source "$LIB_DIR/cores.sh"

CONFIG_FILE=""
OPT_FORCE=0
usage() {
    cat <<EOF
Usage: scripts/install-cores.sh [--config FILE] [--force] [--dry-run] [-y] [-v]

Download the libretro cores required by your selected RetroArch systems from the
official libretro buildbot into RetroArch's Flatpak cores directory.
(deploy.sh runs this automatically when install_cores: yes.)

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

main() {
    config_set_defaults
    [[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
    detect_all
    log_init ""
    is_dry_run && log_warn "DRY-RUN MODE — nothing will be downloaded"

    local cores; mapfile -t cores < <(cores_collect)
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

    cores_install "$OPT_FORCE"; local rc=$?
    backup_finalize

    log_step "Core install summary"
    printf '  installed/ok : %d\n  failed       : %d\n  cores dir    : %s\n' \
        "${#PBC_CORES_OK[@]}" "${#PBC_CORES_FAILED[@]}" "$(ra_core_dir)"
    is_dry_run && printf '\n%sThis was a DRY RUN — nothing was downloaded.%s\n' "$C_YELLOW" "$C_RESET"
    return $rc
}

main "$@"
