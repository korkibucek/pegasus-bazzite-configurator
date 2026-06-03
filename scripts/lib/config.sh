#!/usr/bin/env bash
# config.sh — configuration model: defaults, a dependency-free YAML-subset
# parser, interactive prompts, and validation.
#
# We intentionally do NOT depend on `yq`: a minimal Bazzite/Fedora userspace
# may not have it, and the smoke-test container should not need extra packages.
# The parser supports the small YAML subset used by example-config.yaml:
#   key: value                 # scalar
#   key: a, b, c               # inline comma list
#   key:                       # block sequence
#     - item1
#     - item2
#   # comment lines and blanks are ignored

# ---------------------------------------------------------------------------
# Defaults. Every CFG_* variable is set here so the rest of the code can rely
# on them existing. Interactive/file config overrides these.
# ---------------------------------------------------------------------------
config_set_defaults() {
    CFG_ROM_ROOT="${CFG_ROM_ROOT:-$HOME/ROMs}"
    CFG_CREATE_ROM_DIR="${CFG_CREATE_ROM_DIR:-yes}"
    CFG_PEGASUS_INSTALL="${CFG_PEGASUS_INSTALL:-flatpak}"   # flatpak|appimage|skip
    CFG_PEGASUS_CONFIG_DIR="${CFG_PEGASUS_CONFIG_DIR:-auto}" # auto => derive from install method
    CFG_MEDIA_DIRNAME="${CFG_MEDIA_DIRNAME:-media}"          # media subdir per system
    CFG_EMULATORS="${CFG_EMULATORS:-retroarch dolphin pcsx2 ppsspp duckstation}"
    CFG_SYSTEMS="${CFG_SYSTEMS:-auto}"                       # auto => systems whose emulator is selected
    CFG_MODE="${CFG_MODE:-install-missing}"                  # install-missing|force
    CFG_BACKUP="${CFG_BACKUP:-yes}"
    CFG_EXAMPLE_COLLECTIONS="${CFG_EXAMPLE_COLLECTIONS:-yes}"
    CFG_CONTROLLER_FRIENDLY="${CFG_CONTROLLER_FRIENDLY:-yes}"
    CFG_TARGET="${CFG_TARGET:-auto}"                         # auto|gamemode|desktop
    CFG_EXTRA_ROM_PATHS="${CFG_EXTRA_ROM_PATHS:-}"           # extra mounts to grant (SD cards etc.)
    # Per-system emulator overrides: space/comma list of "shortname=emulator[:core]"
    CFG_SYSTEM_EMULATORS="${CFG_SYSTEM_EMULATORS:-}"
    # Reuse a detected EmuDeck/ES-DE library as rom_root: auto|yes|no
    CFG_REUSE_LIBRARY="${CFG_REUSE_LIBRARY:-auto}"
}

# ---------------------------------------------------------------------------
# YAML-subset parser
# ---------------------------------------------------------------------------

# _yaml_key_to_cfg KEY -> CFG_ variable name, or empty if unknown.
_yaml_key_to_cfg() {
    case "$1" in
        rom_root)              echo CFG_ROM_ROOT ;;
        create_rom_dir)        echo CFG_CREATE_ROM_DIR ;;
        pegasus_install)       echo CFG_PEGASUS_INSTALL ;;
        pegasus_config_dir)    echo CFG_PEGASUS_CONFIG_DIR ;;
        media_dirname)         echo CFG_MEDIA_DIRNAME ;;
        emulators)             echo CFG_EMULATORS ;;
        systems)               echo CFG_SYSTEMS ;;
        mode)                  echo CFG_MODE ;;
        backup)                echo CFG_BACKUP ;;
        example_collections)   echo CFG_EXAMPLE_COLLECTIONS ;;
        controller_friendly)   echo CFG_CONTROLLER_FRIENDLY ;;
        target)                echo CFG_TARGET ;;
        extra_rom_paths)       echo CFG_EXTRA_ROM_PATHS ;;
        system_emulators)      echo CFG_SYSTEM_EMULATORS ;;
        reuse_existing_library) echo CFG_REUSE_LIBRARY ;;
        *)                     echo "" ;;
    esac
}

_strip_inline_comment_and_quotes() {
    local v="$1"
    # Remove a trailing " # comment" (only when preceded by whitespace).
    v="$(sed -E 's/[[:space:]]+#.*$//' <<<"$v")"
    v="$(trim "$v")"
    # Strip surrounding quotes if present.
    if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then v="${v:1:-1}"; fi
    printf '%s' "$v"
}

# parse_config_file FILE — populate CFG_* from a YAML-subset file.
parse_config_file() {
    local file="$1"
    [[ -r "$file" ]] || die "config file not readable: $file"
    config_set_defaults
    local line raw key val cur_var="" collecting=0 listval=""
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line="${raw%$'\r'}"                       # tolerate CRLF
        # Block-sequence item for the current key?
        if [[ "$collecting" == 1 && "$line" =~ ^[[:space:]]+-[[:space:]]*(.*)$ ]]; then
            local item; item="$(_strip_inline_comment_and_quotes "${BASH_REMATCH[1]}")"
            [[ -n "$item" ]] && listval+="${listval:+ }$item"
            continue
        elif [[ "$collecting" == 1 ]]; then
            # End of the block sequence — commit it.
            [[ -n "$cur_var" ]] && printf -v "$cur_var" '%s' "$listval"
            collecting=0; cur_var=""; listval=""
        fi
        # Skip comments / blanks.
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]] && continue
        # Top-level key: value
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
            local var; var="$(_yaml_key_to_cfg "$key")"
            [[ -z "$var" ]] && { log_warn "config: ignoring unknown key '$key'"; continue; }
            if [[ -z "$(trim "$val")" ]]; then
                # Possibly the start of a block sequence.
                collecting=1; cur_var="$var"; listval=""
            else
                val="$(_strip_inline_comment_and_quotes "$val")"
                # Inline comma list -> space-separated.
                if [[ "$val" == *,* ]]; then
                    val="$(tr ',' ' ' <<<"$val" | tr -s ' ')"; val="$(trim "$val")"
                fi
                printf -v "$var" '%s' "$val"
            fi
        fi
    done <"$file"
    # Commit a trailing block sequence at EOF.
    [[ "$collecting" == 1 && -n "$cur_var" ]] && printf -v "$cur_var" '%s' "$listval"
    return 0
}

# ---------------------------------------------------------------------------
# Interactive prompts
# ---------------------------------------------------------------------------

# config_interactive — ask the user the configuration questions, seeding
# defaults from detection. Skipped entirely when ASSUME_YES=1.
config_interactive() {
    config_set_defaults
    log_step "Configuration"
    # Adapt defaults to detected form factor before prompting.
    if [[ "$CFG_TARGET" == auto ]]; then
        [[ "${PBC_FORM_FACTOR:-}" == handheld ]] && CFG_TARGET=gamemode || CFG_TARGET=desktop
    fi
    if [[ "$ASSUME_YES" == 1 ]]; then
        log_info "non-interactive mode: using configured/default values"
        return 0
    fi

    CFG_ROM_ROOT="$(ask "ROM root directory" "$CFG_ROM_ROOT")"
    # Guide the user away from non-writable roots (e.g. /var/ROMS) before we get
    # to the fatal prerequisite check — offer concrete writable options (#46).
    local _wtries=0
    while ! path_is_writable "$CFG_ROM_ROOT"; do
        log_warn "Not writable: $CFG_ROM_ROOT — this tool never uses root."
        echo "Writable options on this system:"; rom_root_suggestions | sed 's/^/  - /'
        _wtries=$((_wtries + 1))
        [[ "$_wtries" -ge 3 ]] && { log_warn "continuing with '$CFG_ROM_ROOT'; the prerequisite check will re-flag it"; break; }
        CFG_ROM_ROOT="$(ask "ROM root directory (writable)" "$HOME/ROMs")"
    done
    if [[ ! -d "$CFG_ROM_ROOT" ]]; then
        ask_yes_no "ROM root '$CFG_ROM_ROOT' does not exist. Create it?" Y \
            && CFG_CREATE_ROM_DIR=yes || CFG_CREATE_ROM_DIR=no
    fi

    echo "Available emulators:"
    local k i=1
    for k in "${EMU_ORDER[@]}"; do printf '  %2d) %-28s %s\n' "$i" "$k" "${EMU_NAME[$k]}"; i=$((i+1)); done
    local sel; sel="$(ask "Emulators to install (space-separated keys, or 'all')" "$CFG_EMULATORS")"
    [[ "$sel" == all ]] && sel="${EMU_ORDER[*]}"
    CFG_EMULATORS="$sel"

    ask_yes_no "Force reconfigure everything (overwrite existing)? Otherwise only install/configure what's missing" N \
        && CFG_MODE=force || CFG_MODE=install-missing
    ask_yes_no "Back up existing Pegasus config before changes?" Y && CFG_BACKUP=yes || CFG_BACKUP=no
    ask_yes_no "Create example collections for systems with no ROMs yet?" Y && CFG_EXAMPLE_COLLECTIONS=yes || CFG_EXAMPLE_COLLECTIONS=no
    ask_yes_no "Apply controller-friendly emulator launch defaults?" Y && CFG_CONTROLLER_FRIENDLY=yes || CFG_CONTROLLER_FRIENDLY=no

    local extra; extra="$(ask "Extra ROM paths to grant emulators (e.g. SD card mount), space-separated, or blank" "$CFG_EXTRA_ROM_PATHS")"
    CFG_EXTRA_ROM_PATHS="$extra"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# config_validate — fail fast with a clear message on the offending key.
config_validate() {
    local errors=0
    _cfg_err() { log_error "config: $*"; errors=$((errors+1)); }

    [[ -n "$CFG_ROM_ROOT" ]] || _cfg_err "rom_root must not be empty"
    [[ "$CFG_ROM_ROOT" == /* ]] || _cfg_err "rom_root must be an absolute path (got '$CFG_ROM_ROOT')"

    case "$CFG_PEGASUS_INSTALL" in flatpak|appimage|skip) ;; *) _cfg_err "pegasus_install must be flatpak|appimage|skip (got '$CFG_PEGASUS_INSTALL')";; esac
    case "$CFG_MODE" in install-missing|force) ;; *) _cfg_err "mode must be install-missing|force (got '$CFG_MODE')";; esac
    case "$CFG_TARGET" in auto|gamemode|desktop) ;; *) _cfg_err "target must be auto|gamemode|desktop (got '$CFG_TARGET')";; esac
    case "$CFG_REUSE_LIBRARY" in auto|yes|no) ;; *) _cfg_err "reuse_existing_library must be auto|yes|no (got '$CFG_REUSE_LIBRARY')";; esac
    _cfg_bool() { case "${1,,}" in yes|no|true|false|1|0) return 0;; *) return 1;; esac; }
    _cfg_bool "$CFG_CREATE_ROM_DIR"      || _cfg_err "create_rom_dir must be yes/no"
    _cfg_bool "$CFG_BACKUP"              || _cfg_err "backup must be yes/no"
    _cfg_bool "$CFG_EXAMPLE_COLLECTIONS" || _cfg_err "example_collections must be yes/no"
    _cfg_bool "$CFG_CONTROLLER_FRIENDLY" || _cfg_err "controller_friendly must be yes/no"

    # Validate every selected emulator key against the catalog.
    local k
    for k in $CFG_EMULATORS; do
        emu_exists "$k" || _cfg_err "unknown emulator '$k' (see config/example-config.yaml for valid keys)"
    done

    # Validate per-system emulator overrides: "shortname=emulator[:core]".
    local tok sn rhs emu
    for tok in $CFG_SYSTEM_EMULATORS; do
        if [[ "$tok" != *=* ]]; then
            _cfg_err "system_emulators: '$tok' must be shortname=emulator[:core]"; continue
        fi
        sn="${tok%%=*}"; rhs="${tok#*=}"; emu="${rhs%%:*}"
        [[ -r "$PBC_SYSTEMS_DIR/$sn.conf" ]] || _cfg_err "system_emulators: unknown system '$sn'"
        emu_exists "$emu" || { _cfg_err "system_emulators: unknown emulator '$emu' for '$sn'"; continue; }
        # RetroArch needs a core: from the override (sn=retroarch:core) or the
        # system's own definition.
        if [[ "$emu" == retroarch && "$rhs" != *:* ]]; then
            local cconf=""
            [[ -r "$PBC_SYSTEMS_DIR/$sn.conf" ]] && cconf="$(_sys_field "$sn" SYS_RA_CORE 2>/dev/null)"
            [[ -n "$cconf" ]] || _cfg_err "system_emulators: '$sn=retroarch' needs a core (use '$sn=retroarch:<core>')"
        fi
    done

    (( errors == 0 )) || { log_error "$errors configuration error(s); aborting"; return 1; }
    log_ok "configuration valid"
    return 0
}

# cfg_is_yes VALUE -> 0 for yes/true/1.
cfg_is_yes() { case "${1,,}" in yes|true|1) return 0;; *) return 1;; esac; }

# config_summary — echo the effective config (for logs and confirmation).
config_summary() {
    cat <<EOF
  ROM root            : $CFG_ROM_ROOT
  Create ROM dir      : $CFG_CREATE_ROM_DIR
  Pegasus install     : $CFG_PEGASUS_INSTALL
  Pegasus config dir  : $CFG_PEGASUS_CONFIG_DIR
  Media subdir        : $CFG_MEDIA_DIRNAME
  Emulators           : $CFG_EMULATORS
  Systems             : $CFG_SYSTEMS
  Mode                : $CFG_MODE
  Backup existing     : $CFG_BACKUP
  Example collections : $CFG_EXAMPLE_COLLECTIONS
  Controller-friendly : $CFG_CONTROLLER_FRIENDLY
  Target              : $CFG_TARGET
  Extra ROM paths     : ${CFG_EXTRA_ROM_PATHS:-（none）}
  System overrides    : ${CFG_SYSTEM_EMULATORS:-（none）}
  Reuse library       : $CFG_REUSE_LIBRARY
EOF
}
