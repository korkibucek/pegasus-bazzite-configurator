#!/usr/bin/env bash
# deploy.sh — zero-touch Pegasus Frontend + emulator configurator for Bazzite.
#
# Usage:
#   ./scripts/deploy.sh                          # interactive
#   ./scripts/deploy.sh --config config/example-config.yaml
#   ./scripts/deploy.sh --config FILE --non-interactive
#   ./scripts/deploy.sh --dry-run                # preview, change nothing
#   ./scripts/deploy.sh --restore [DIR]          # restore from a backup
#
# Designed for Bazzite (Fedora Atomic / Universal Blue). Prefers Flatpak +
# user-space configuration; never layers rpm-ostree packages or requires root.
set -Eeuo pipefail

PBC_VERSION="1.0.0"

# --- locate ourselves -------------------------------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
export PBC_SYSTEMS_DIR="$REPO_ROOT/config/systems"

# --- source libraries -------------------------------------------------------
# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=scripts/lib/emulators.sh
source "$LIB_DIR/emulators.sh"
# shellcheck source=scripts/lib/prereq.sh
source "$LIB_DIR/prereq.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB_DIR/backup.sh"
# shellcheck source=scripts/lib/pegasus.sh
source "$LIB_DIR/pegasus.sh"

# --- summary accumulators ---------------------------------------------------
declare -a PBC_OUTSTANDING=() PBC_SYSTEMS_WRITTEN=() PBC_SYSTEMS_SKIPPED=()
PBC_PEGASUS_INSTALLED=0

usage() {
    cat <<EOF
pegasus-bazzite-configurator v$PBC_VERSION

Configure Pegasus Frontend + emulator backends on Bazzite (Fedora Atomic).

USAGE:
  scripts/deploy.sh [OPTIONS]

OPTIONS:
  -c, --config FILE     Load configuration from a YAML file (see
                        config/example-config.yaml).
  -n, --non-interactive Never prompt; use config file + defaults. Implies -y.
  -y, --yes             Assume "yes"/defaults for all prompts.
      --dry-run         Print everything that would change; change nothing.
  -f, --force           Force reconfigure (overwrite existing metadata).
      --allow-non-bazzite  Continue even if the OS is not detected as Bazzite.
      --restore [DIR]   Restore Pegasus config from a backup (latest if DIR
                        omitted) and exit.
  -q, --quiet           Suppress INFO output (errors/warnings still shown).
  -v, --verbose         Verbose/debug output.
  -V, --version         Print version and exit.
  -h, --help            Show this help and exit.

EXAMPLES:
  scripts/deploy.sh
  scripts/deploy.sh --config config/example-config.yaml --dry-run
  scripts/deploy.sh --config config/example-config.yaml --non-interactive
  scripts/deploy.sh --restore
EOF
}

# --- argument parsing -------------------------------------------------------
CONFIG_FILE=""
ALLOW_NON_BAZZITE=0
DO_RESTORE=0
RESTORE_DIR=""
OPT_FORCE=0   # CLI --force; applied AFTER config-file load so the flag wins
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)        CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        -n|--non-interactive) ASSUME_YES=1; shift ;;
        -y|--yes)           ASSUME_YES=1; shift ;;
        --dry-run)          DRY_RUN=1; shift ;;
        -f|--force)         OPT_FORCE=1; shift ;;
        --allow-non-bazzite) ALLOW_NON_BAZZITE=1; shift ;;
        --restore)          DO_RESTORE=1
                            if [[ -n "${2:-}" && "${2:0:1}" != "-" ]]; then RESTORE_DIR="$2"; shift; fi
                            shift ;;
        -q|--quiet)         QUIET=1; shift ;;
        -v|--verbose)       VERBOSE=1; shift ;;
        -V|--version)       echo "$PBC_VERSION"; exit 0 ;;
        -h|--help)          usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Trap unexpected errors with a useful message and line number.
trap 'log_error "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"; exit 1' ERR

main() {
    log_init ""
    log_step "pegasus-bazzite-configurator v$PBC_VERSION"
    is_dry_run && log_warn "DRY-RUN MODE — no changes will be made"
    [[ -n "$LOG_FILE" ]] && log_info "log file: $LOG_FILE"

    # --- detection ----------------------------------------------------------
    log_step "Detecting platform"
    detect_all
    log_info "OS: $(os_summary_line)"
    if [[ "${PBC_IS_BAZZITE:-0}" != 1 ]]; then
        if [[ "$ALLOW_NON_BAZZITE" == 1 ]]; then
            log_warn "not detected as Bazzite — continuing because --allow-non-bazzite was given"
        elif [[ "${PBC_IS_FEDORA_LIKE:-0}" == 1 ]]; then
            log_warn "not Bazzite, but Fedora-like detected. This is supported for testing/config only."
            log_warn "Re-run with --allow-non-bazzite to proceed with installs on this system."
            [[ "$ASSUME_YES" == 1 ]] || ask_yes_no "Continue anyway?" N || die "aborted by user"
        else
            die "This tool targets Bazzite / Fedora Atomic. Detected: $(os_summary_line). Use --allow-non-bazzite to override."
        fi
    fi

    # --- configuration ------------------------------------------------------
    config_set_defaults
    if [[ -n "$CONFIG_FILE" ]]; then
        log_info "loading config: $CONFIG_FILE"
        parse_config_file "$CONFIG_FILE"
    fi
    config_interactive
    # CLI flags take precedence over the config file / prompts.
    [[ "$OPT_FORCE" == 1 ]] && CFG_MODE=force
    [[ "$CFG_TARGET" == auto ]] && { [[ "${PBC_FORM_FACTOR:-}" == handheld ]] && CFG_TARGET=gamemode || CFG_TARGET=desktop; }
    log_step "Effective configuration"
    config_summary | tee -a "${LOG_FILE:-/dev/null}" 2>/dev/null || config_summary
    config_validate || die "configuration invalid"

    if [[ "$ASSUME_YES" != 1 ]] && ! is_dry_run; then
        ask_yes_no "Proceed with this configuration?" Y || die "aborted by user"
    fi

    # --- prerequisites ------------------------------------------------------
    run_all_prereqs "$CFG_ROM_ROOT" || die "prerequisite checks failed; resolve the issues above and re-run"

    # --- execute ------------------------------------------------------------
    pegasus_install     || log_error "Pegasus install step reported a problem"
    log_step "Installing emulators"
    # Intentional word-splitting: CFG_EXTRA_ROM_PATHS is a space/comma list of
    # extra mounts to grant, each passed as its own argument.
    # shellcheck disable=SC2086
    emu_install_selected "$CFG_EMULATORS" "$CFG_ROM_ROOT" $CFG_EXTRA_ROM_PATHS \
        || log_error "Emulator install step reported a problem"
    pegasus_generate    || log_error "Config generation reported a problem"
    backup_finalize

    print_summary
    if [[ "$PBC_HAD_ERRORS" == 1 ]]; then
        log_warn "Completed with one or more errors — review the log: ${LOG_FILE:-<none>}"
        exit 1
    fi
    return 0
}

print_summary() {
    pegasus_resolve_config_dir 2>/dev/null || true
    local pega="not installed"
    if [[ "$PBC_PEGASUS_INSTALLED" == 1 ]]; then pega="installed now (flatpak)"
    elif flatpak info "$PEGASUS_FLATPAK_ID" >/dev/null 2>&1; then pega="present (flatpak)"
    elif [[ "$CFG_PEGASUS_INSTALL" == appimage ]]; then pega="AppImage (manual step pending)"
    elif [[ "$CFG_PEGASUS_INSTALL" == skip ]]; then pega="skipped by config"; fi

    log_step "Deployment summary"
    cat <<EOF
${C_BOLD}Pegasus${C_RESET}        : $pega
${C_BOLD}Emulators${C_RESET}      :
  installed now : ${PBC_EMU_INSTALLED[*]:-（none）}
  already present: ${PBC_EMU_SKIPPED[*]:-（none）}
  failed         : ${PBC_EMU_FAILED[*]:-（none）}
${C_BOLD}Systems${C_RESET}        :
  written        : ${PBC_SYSTEMS_WRITTEN[*]:-（none）}
  left untouched : ${PBC_SYSTEMS_SKIPPED[*]:-（none）}
${C_BOLD}ROM root${C_RESET}       : $CFG_ROM_ROOT
${C_BOLD}Config path${C_RESET}    : ${PEGASUS_CONFIG_DIR:-<unresolved>}
${C_BOLD}Backup path${C_RESET}    : ${PBC_BACKUP_DIR:-（no backup needed）}
${C_BOLD}Log file${C_RESET}       : ${LOG_FILE:-<none>}
EOF

    if [[ ${#PBC_OUTSTANDING[@]} -gt 0 ]]; then
        printf '\n%sOutstanding user actions:%s\n' "$C_YELLOW" "$C_RESET"
        local a; for a in "${PBC_OUTSTANDING[@]}"; do printf '  • %s\n' "$a"; done
    fi
    # Always-relevant manual notes.
    if [[ " $CFG_EMULATORS " == *" retroarch "* ]]; then
        printf '  • RetroArch: install the cores listed in each system'\''s metadata via Online Updater > Core Downloader.\n'
    fi

    cat <<EOF

${C_BOLD}Next steps${C_RESET}
  Launch Pegasus :  flatpak run $PEGASUS_FLATPAK_ID
                    (or add it to Steam and launch from Game Mode)
  Validate       :  scripts/validate.sh${CONFIG_FILE:+ --config $CONFIG_FILE}
  Re-run         :  scripts/deploy.sh${CONFIG_FILE:+ --config $CONFIG_FILE}
  Undo/restore   :  scripts/restore.sh${PBC_BACKUP_DIR:+ "$PBC_BACKUP_DIR"}

Place legally obtained ROMs under: $CFG_ROM_ROOT/<system>/
No BIOS, ROMs, firmware, or keys are installed by this tool.
EOF
    if is_dry_run; then
        printf '\n%sThis was a DRY RUN — nothing above was actually changed.%s\n' "$C_YELLOW" "$C_RESET"
    fi
    # Must return success: this is the last statement of a normal run and runs
    # under `set -e` + ERR trap. A bare `is_dry_run && ...` would return 1 on a
    # real (non-dry) run and spuriously trip the trap.
    return 0
}

# --- restore shortcut -------------------------------------------------------
if [[ "$DO_RESTORE" == 1 ]]; then
    log_init ""
    backup_restore "$RESTORE_DIR"
    exit $?
fi

main "$@"
