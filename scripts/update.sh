#!/usr/bin/env bash
# update.sh — update the Flatpaks this tool manages (Pegasus + configured
# emulators) at --user scope. Does not change any configuration.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
export PBC_SYSTEMS_DIR="$REPO_ROOT/config/systems"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/emulators.sh
source "$LIB_DIR/emulators.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"

CONFIG_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)
            echo "Usage: scripts/update.sh [--config FILE] [--dry-run] [-v]"
            echo "Runs 'flatpak update --user' for Pegasus + the configured emulators."
            exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

config_set_defaults
[[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
log_init ""
is_dry_run && log_warn "DRY-RUN MODE — no updates will be applied"

if ! have flatpak && ! is_dry_run; then
    die "flatpak is not installed; nothing to update"
fi

# Build the list of app-ids we manage.
apps=()
[[ "$CFG_PEGASUS_INSTALL" != skip ]] && apps+=("$PEGASUS_FLATPAK_ID")
for k in $CFG_EMULATORS; do
    emu_exists "$k" && apps+=("${EMU_ID[$k]}")
done

if [[ ${#apps[@]} -eq 0 ]]; then
    log_warn "no managed Flatpaks to update"
    exit 0
fi

log_step "Updating ${#apps[@]} Flatpak(s)"
log_info "apps: ${apps[*]}"
# A single update call is fine; unknown/uninstalled ids are simply skipped by
# flatpak. Update only those actually installed to keep output clean.
to_update=()
for a in "${apps[@]}"; do
    if is_dry_run || flatpak info "$a" >/dev/null 2>&1; then
        to_update+=("$a")
    else
        log_info "not installed, skipping: $a"
    fi
done

if [[ ${#to_update[@]} -eq 0 ]]; then
    log_warn "none of the managed Flatpaks are installed"
    exit 0
fi

run_cmd flatpak update --user --noninteractive --assumeyes "${to_update[@]}"
log_ok "update complete"
