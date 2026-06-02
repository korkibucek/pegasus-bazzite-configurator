#!/usr/bin/env bash
# common.sh — shared helpers: logging, colored output, the dry-run executor.
#
# This file is sourced by deploy.sh, validate.sh, restore.sh and the test
# suite. It deliberately does NOT enable strict mode (the entrypoint owns
# that) and defines no top-level side effects beyond variable defaults, so it
# is safe to source in isolation for unit testing.

# ---------------------------------------------------------------------------
# Global state (overridable by the entrypoint before/while sourcing)
# ---------------------------------------------------------------------------
: "${DRY_RUN:=0}"          # 1 => print actions instead of running them
: "${QUIET:=0}"            # 1 => suppress INFO/DEBUG on stdout
: "${VERBOSE:=0}"          # 1 => also emit DEBUG
: "${ASSUME_YES:=0}"       # 1 => non-interactive; never prompt
: "${LOG_FILE:=}"          # populated by log_init(); empty => no file logging
: "${PBC_HAD_ERRORS:=0}"   # set to 1 by log_error so callers can detect issues

# Where runtime artifacts (logs, backups) live. Honors XDG.
: "${PBC_STATE_DIR:=${XDG_DATA_HOME:-$HOME/.local/share}/pegasus-bazzite-configurator}"

# Flathub application id for Pegasus Frontend (used across detect/install).
: "${PEGASUS_FLATPAK_ID:=org.pegasus_frontend.Pegasus}"

# ---------------------------------------------------------------------------
# Colors — disabled automatically when stdout is not a TTY or NO_COLOR is set.
# ---------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
    C_RESET=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_DIM=''
fi

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# log_init [explicit-log-path]
# Creates the log directory and opens a timestamped log file. Safe to call
# once; subsequent calls are ignored. In dry-run we still log to a file so the
# user has a record of what *would* have happened.
log_init() {
    [[ -n "$LOG_FILE" ]] && return 0
    local dir="$PBC_STATE_DIR/logs"
    if [[ -n "${1:-}" ]]; then
        LOG_FILE="$1"; dir="$(dirname -- "$LOG_FILE")"
    else
        LOG_FILE="$dir/deploy-$(_timestamp).log"
    fi
    if ! mkdir -p -- "$dir" 2>/dev/null; then
        # Non-fatal: fall back to stdout-only logging.
        printf '%s\n' "${C_YELLOW}warning:${C_RESET} cannot create log dir '$dir'; file logging disabled" >&2
        LOG_FILE=""
        return 0
    fi
    : >"$LOG_FILE" 2>/dev/null || LOG_FILE=""
}

_timestamp() { date +%Y%m%d-%H%M%S; }
_iso_now()   { date +%Y-%m-%dT%H:%M:%S%z; }

# _log LEVEL COLOR MESSAGE... — internal. Writes to the log file always and to
# the terminal subject to QUIET/VERBOSE.
_log() {
    local level="$1" color="$2"; shift 2
    local msg="$*" line
    line="[$(_iso_now)] [$level] $msg"
    if [[ -n "$LOG_FILE" ]]; then printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true; fi
    case "$level" in
        DEBUG) [[ "$VERBOSE" == 1 ]] || return 0 ;;
        INFO)  [[ "$QUIET" == 1 ]]   && return 0 ;;
    esac
    if [[ "$level" == ERROR || "$level" == WARN ]]; then
        printf '%s%s%s %s\n' "$color" "$level:" "$C_RESET" "$msg" >&2
    else
        printf '%s%s%s %s\n' "$color" "$level:" "$C_RESET" "$msg"
    fi
}

log_debug() { _log DEBUG "$C_DIM"    "$@"; }
log_info()  { _log INFO  "$C_BLUE"   "$@"; }
log_ok()    { _log INFO  "$C_GREEN"  "$@"; }
log_warn()  { _log WARN  "$C_YELLOW" "$@"; }
log_error() { PBC_HAD_ERRORS=1; _log ERROR "$C_RED" "$@"; }

# log_step "Title" — visual section divider in the terminal and log.
log_step() {
    if [[ -n "$LOG_FILE" ]]; then printf '\n=== %s ===\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; fi
    [[ "$QUIET" == 1 ]] && return 0
    printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}

# die MESSAGE [exit-code] — log an error and exit.
die() { log_error "$*"; exit "${2:-1}"; }

# ---------------------------------------------------------------------------
# The dry-run executor — the single chokepoint for state-changing commands.
# Every install/override/file-write side effect should flow through run_cmd
# (or check IS_DRY_RUN) so that --dry-run is honored everywhere by construction.
# ---------------------------------------------------------------------------

is_dry_run() { [[ "$DRY_RUN" == 1 ]]; }

# run_cmd cmd args... — execute (or, in dry-run, print) a command. Arguments
# are passed verbatim, so quoting/spaces are preserved correctly.
run_cmd() {
    if is_dry_run; then
        printf '%s[dry-run]%s %s\n' "$C_DIM" "$C_RESET" "$(_quote_args "$@")"
        if [[ -n "$LOG_FILE" ]]; then printf '[%s] [DRYRUN] %s\n' "$(_iso_now)" "$(_quote_args "$@")" >>"$LOG_FILE" 2>/dev/null || true; fi
        return 0
    fi
    log_debug "exec: $(_quote_args "$@")"
    "$@"
}

# _quote_args — render an argv as a copy-pasteable, shell-safe string for logs.
_quote_args() {
    local out='' a
    for a in "$@"; do
        if [[ "$a" =~ [^a-zA-Z0-9_./:=@%+-] || -z "$a" ]]; then
            out+=" '${a//\'/\'\\\'\'}'"
        else
            out+=" $a"
        fi
    done
    printf '%s' "${out# }"
}

# write_file PATH < CONTENT (on stdin) — dry-run-aware file writer that creates
# parent dirs and reports the action. Reads desired content from stdin.
write_file() {
    local path="$1" content; content="$(cat)"
    if is_dry_run; then
        printf '%s[dry-run]%s write %s (%d bytes)\n' "$C_DIM" "$C_RESET" "$path" "${#content}"
        if [[ -n "$LOG_FILE" ]]; then printf '[%s] [DRYRUN] write %s\n' "$(_iso_now)" "$path" >>"$LOG_FILE" 2>/dev/null || true; fi
        return 0
    fi
    mkdir -p -- "$(dirname -- "$path")" || { log_error "cannot create dir for $path"; return 1; }
    # `content` came from $(cat), which strips trailing newlines, so add exactly
    # one. POSIX text files (and .editorconfig) want a final newline; without it,
    # appending to e.g. game_dirs.txt would glue onto the last line.
    printf '%s\n' "$content" >"$path" || { log_error "cannot write $path"; return 1; }
    log_debug "wrote $path"
}

# ---------------------------------------------------------------------------
# Prompt helpers (no-op friendly in non-interactive mode)
# ---------------------------------------------------------------------------

# ask "Question" "default" -> echoes the answer (or default when ASSUME_YES).
ask() {
    local q="$1" def="${2:-}" ans
    if [[ "$ASSUME_YES" == 1 ]]; then printf '%s' "$def"; return 0; fi
    if [[ -n "$def" ]]; then
        read -r -p "$q [$def]: " ans </dev/tty || ans=""
    else
        read -r -p "$q: " ans </dev/tty || ans=""
    fi
    printf '%s' "${ans:-$def}"
}

# ask_yes_no "Question" "Y|N" -> returns 0 for yes, 1 for no.
ask_yes_no() {
    local q="$1" def="${2:-N}" ans
    if [[ "$ASSUME_YES" == 1 ]]; then
        [[ "${def^^}" == Y* ]]; return
    fi
    local hint="y/N"; [[ "${def^^}" == Y* ]] && hint="Y/n"
    read -r -p "$q [$hint]: " ans </dev/tty || ans=""
    ans="${ans:-$def}"
    [[ "${ans^^}" == Y* ]]
}

# ---------------------------------------------------------------------------
# Small utilities
# ---------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

# trim leading/trailing whitespace from $1.
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

# human_bytes KILOBYTES -> e.g. "12.3 GiB" (input is in KiB, matching df -k).
human_kib() {
    local kib="$1"
    awk -v k="$kib" 'BEGIN{
        split("KiB MiB GiB TiB", u); s=1;
        while (k>=1024 && s<4){k/=1024; s++}
        printf "%.1f %s", k, u[s]
    }'
}
