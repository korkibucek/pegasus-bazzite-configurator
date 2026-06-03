#!/usr/bin/env bash
# autoscraper.sh — scrape box art + metadata for your Pegasus collections using
# Skyscraper, built and run in an ISOLATED Podman container.
#
# Why a container? Bazzite is an immutable/atomic OS — you can't just install
# Skyscraper onto the host, and the upstream project is archived while the
# prebuilt images 403. So we compile the maintained `gemba/skyscraper` fork
# inside a throwaway Ubuntu container (built once, cached locally) and run it
# against your ROMs via bind mounts. Nothing is layered onto the host.
#
# It complements deploy.sh: deploy.sh creates the collections + launch commands;
# this fills them with artwork and a richer metadata.pegasus.txt from
# ScreenScraper. Re-running deploy.sh in install-missing mode won't clobber the
# scraped metadata.
#
# Originally contributed by @korkibucek (PR #56), then brought in line with the
# project conventions (lib logging, strict mode, flags, dry-run, no hardcoded
# paths). Verified working on Bazzite.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
export PBC_SYSTEMS_DIR="$REPO_ROOT/config/systems"

# shellcheck source=scripts/lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB_DIR/detect.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB_DIR/config.sh"

IMAGE_NAME="localhost/bazzite-skyscraper"
CACHE_DIR="$HOME/.skyscraper"

# --- args -------------------------------------------------------------------
CONFIG_FILE=""
ROMS_OVERRIDE=""
SYSTEM_ARG=""
SS_USER_ARG=""
REBUILD=0
GENERATE_ONLY=0
usage() {
    cat <<EOF
Usage: scripts/autoscraper.sh [OPTIONS]

Scrape artwork + metadata for your Pegasus collections with Skyscraper, run in
an isolated Podman container (built locally on first use).

OPTIONS:
  -c, --config FILE   Read the ROM root from a deploy config (sets the default).
      --roms DIR      ROM root to scrape (overrides config/prompt).
      --system NAME   System folder to scrape (e.g. snes), or 'all'.
  -u, --user USER     ScreenScraper username (you'll be prompted for the password).
      --rebuild       Rebuild the Skyscraper container image even if it exists.
  -G, --generate-only Skip the ScreenScraper gather pass; only (re)generate
                      metadata.pegasus.txt + media from the existing cache.
      --dry-run       Print the podman build/run commands; change nothing.
  -y, --yes           Non-interactive: use defaults/flags, don't prompt.
  -v, --verbose       Verbose output.
  -h, --help          This help.

Requires Podman (preinstalled on Bazzite). A ScreenScraper account avoids the
strict anonymous rate limits. See docs/SCRAPING.md.
EOF
}
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="${2:?--config requires a path}"; shift 2 ;;
        --roms)      ROMS_OVERRIDE="${2:?--roms requires a path}"; shift 2 ;;
        --system)    SYSTEM_ARG="${2:?--system requires a name}"; shift 2 ;;
        -u|--user)   SS_USER_ARG="${2:?--user requires a value}"; shift 2 ;;
        --rebuild)   REBUILD=1; shift ;;
        -G|--generate-only) GENERATE_ONLY=1; shift ;;
        --dry-run)   DRY_RUN=1; shift ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        -v|--verbose) VERBOSE=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

trap 'log_error "unexpected failure at ${BASH_SOURCE[0]}:${LINENO} (exit $?)"; exit 1' ERR

# resolve_rom_root — pick a sensible default ROM root and (interactively) confirm.
resolve_rom_root() {
    config_set_defaults
    [[ -n "$CONFIG_FILE" ]] && parse_config_file "$CONFIG_FILE"
    local default="$CFG_ROM_ROOT"
    [[ -n "$ROMS_OVERRIDE" ]] && default="$ROMS_OVERRIDE"
    # If no explicit roms/config and rom_root is still the built-in default,
    # prefer a detected EmuDeck/ES-DE library.
    if [[ -z "$ROMS_OVERRIDE" && -z "$CONFIG_FILE" && "$default" == "$HOME/ROMs" ]] \
       && detect_rom_library; then
        default="$PBC_ROM_LIBRARY"
    fi
    if [[ -n "$ROMS_OVERRIDE" || "$ASSUME_YES" == 1 ]]; then
        ROM_DIR="$default"
    else
        ROM_DIR="$(ask "ROMs path to scrape" "$default")"
    fi
}

build_image() {
    log_step "Building the Skyscraper container image ($IMAGE_NAME)"
    log_info "Compiling the maintained gemba/skyscraper fork in an isolated Ubuntu container (one-time, a few minutes)."
    local df; df="$(mktemp)"
    cat >"$df" <<'DOCKERFILE'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y build-essential qtbase5-dev qt5-qmake git wget && \
    git clone https://github.com/gemba/skyscraper.git /usr/src/skyscraper && \
    cd /usr/src/skyscraper && \
    qmake && \
    make -j"$(nproc)" && \
    make install && \
    apt-get clean && rm -rf /var/lib/apt/lists/* /usr/src/skyscraper
ENTRYPOINT ["Skyscraper"]
DOCKERFILE
    run_cmd podman build -t "$IMAGE_NAME" -f "$df" "$(dirname -- "$df")"
    is_dry_run || rm -f "$df"
    log_ok "container image ready"
}

# scrape_system SYS ROM_DIR [AUTH_ARGS...] — the two-pass Skyscraper run.
#
# Two details that make the output usable by Pegasus (issue #60):
#  * The ROM dir is bind-mounted at its REAL host path (not /roms), so the
#    absolute file:/assets.* paths Skyscraper writes into metadata.pegasus.txt
#    are valid on the host where Pegasus reads them.
#  * `--flags unattend` makes Skyscraper overwrite the deploy-created
#    metadata.pegasus.txt without an interactive prompt, while preserving its
#    existing collection/shortname/launch/extensions header. Without it,
#    Skyscraper asks "overwrite? (y/N)" and writes nothing on a non-"y" answer.
scrape_system() {
    local sys="$1" rom_dir="$2"; shift 2
    log_step "Processing: $sys"
    # Interactive TTY only when we actually have one (lets -y/headless runs work).
    local tty=(); [[ -t 0 && -t 1 ]] && tty=(-it)
    # Pass 1: gather artwork + metadata from ScreenScraper into the cache.
    if [[ "$GENERATE_ONLY" != 1 ]]; then
        run_cmd podman run --rm "${tty[@]}" \
            -v "$rom_dir:$rom_dir:Z" \
            -v "$CACHE_DIR:/root/.skyscraper:Z" \
            "$IMAGE_NAME" \
            --flags unattend -p "$sys" -s screenscraper -i "$rom_dir/$sys" "$@"
    else
        log_info "$sys: --generate-only — skipping the ScreenScraper gather pass"
    fi
    # Pass 2: generate metadata.pegasus.txt + media from the cache.
    run_cmd podman run --rm "${tty[@]}" \
        -v "$rom_dir:$rom_dir:Z" \
        -v "$CACHE_DIR:/root/.skyscraper:Z" \
        "$IMAGE_NAME" \
        --flags unattend -p "$sys" -f pegasus -i "$rom_dir/$sys" -g "$rom_dir/$sys"
}

main() {
    log_init ""
    log_step "Pegasus auto-scraper (Skyscraper via Podman)"
    is_dry_run && log_warn "DRY-RUN MODE — no container build/run will happen"

    if ! is_dry_run && ! have podman; then
        die "podman is required (preinstalled on Bazzite); not found"
    fi

    resolve_rom_root
    [[ -d "$ROM_DIR" ]] || die "ROM directory not found: $ROM_DIR"
    log_info "ROM root: $ROM_DIR"
    run_cmd mkdir -p -- "$CACHE_DIR"   # ensure cache exists with user ownership

    # Build the image on first use (or when forced / previewing).
    if [[ "$REBUILD" == 1 ]] || is_dry_run || ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
        build_image
    else
        log_ok "Skyscraper image present — skipping build"
    fi

    # Which systems?
    local system="$SYSTEM_ARG"
    if [[ -z "$system" ]]; then
        if [[ "$ASSUME_YES" == 1 ]]; then system="all"; else
            system="$(ask "System folder to scrape (e.g. snes), or 'all'" "all")"
        fi
    fi
    [[ -n "$system" ]] || die "no system specified"

    local systems=()
    if [[ "${system,,}" == "all" ]]; then
        log_info "Scraping every system folder under $ROM_DIR"
        local d
        for d in "$ROM_DIR"/*/; do [[ -d "$d" ]] && systems+=("$(basename -- "$d")"); done
        [[ ${#systems[@]} -gt 0 ]] || die "no system subfolders found under $ROM_DIR"
    else
        systems=("$system")
    fi

    # ScreenScraper credentials (optional; avoids anonymous rate limits).
    # Not needed for --generate-only (no gather pass).
    local ss_user="$SS_USER_ARG" ss_pass="" auth=()
    if [[ "$GENERATE_ONLY" != 1 && "$ASSUME_YES" != 1 && -z "$ss_user" ]]; then
        log_info "ScreenScraper.fr throttles anonymous scraping; an account helps."
        ss_user="$(ask "ScreenScraper username (blank = anonymous)" "")"
    fi
    if [[ -n "$ss_user" ]]; then
        if [[ "$ASSUME_YES" != 1 ]]; then
            read -r -s -p "ScreenScraper password: " ss_pass </dev/tty || ss_pass=""; echo
        fi
        [[ -n "$ss_pass" ]] && auth=("-u" "$ss_user:$ss_pass")
    fi

    log_info "Systems to scrape: ${systems[*]}"
    local sys
    for sys in "${systems[@]}"; do
        scrape_system "$sys" "$ROM_DIR" "${auth[@]}"
    done

    log_step "Done"
    log_ok "Scraping complete for: ${systems[*]}"
    log_info "Launch Pegasus to see the updated artwork/metadata."
    is_dry_run && printf '\n%sThis was a DRY RUN — nothing was built, scraped, or written.%s\n' "$C_YELLOW" "$C_RESET"
    return 0
}

main "$@"
