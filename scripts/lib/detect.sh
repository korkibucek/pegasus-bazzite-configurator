#!/usr/bin/env bash
# detect.sh — defensive OS / platform / form-factor detection.
#
# Bazzite is Fedora Atomic (Universal Blue, rpm-ostree/bootc), NOT Ubuntu and
# NOT a normal mutable Fedora. None of these functions assume the dev host is
# the target; they read evidence and degrade gracefully. All functions are
# pure (no mutation) and export their results into well-known variables so the
# suite can unit-test the parsing against fixture files.

# Allow tests to point detection at a fixture instead of the real file.
: "${OS_RELEASE_FILE:=/etc/os-release}"

# Results (populated by detect_all / individual detectors):
#   PBC_OS_ID            raw ID= from os-release (e.g. bazzite, fedora)
#   PBC_OS_LIKE          ID_LIKE
#   PBC_OS_VARIANT       VARIANT_ID
#   PBC_OS_IMAGE_ID      IMAGE_ID (Universal Blue sets this, e.g. bazzite-deck)
#   PBC_OS_PRETTY        PRETTY_NAME
#   PBC_IS_BAZZITE       1/0
#   PBC_IS_FEDORA_ATOMIC 1/0  (atomic/ostree Fedora-family, may not be Bazzite)
#   PBC_IS_FEDORA_LIKE   1/0  (any Fedora family, incl. plain Fedora container)
#   PBC_IS_ATOMIC        1/0  (ostree-booted / rpm-ostree managed)
#   PBC_FORM_FACTOR      handheld | desktop | unknown
#   PBC_HANDHELD_MODEL   free text (e.g. "Valve Jupiter") when detectable

# _osr KEY — read a value from the os-release file, stripping quotes.
_osr() {
    [[ -r "$OS_RELEASE_FILE" ]] || return 1
    local v
    v="$(awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$OS_RELEASE_FILE")"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

detect_os() {
    PBC_OS_ID="$(_osr ID || true)"
    PBC_OS_LIKE="$(_osr ID_LIKE || true)"
    PBC_OS_VARIANT="$(_osr VARIANT_ID || true)"
    PBC_OS_IMAGE_ID="$(_osr IMAGE_ID || true)"
    PBC_OS_PRETTY="$(_osr PRETTY_NAME || true)"

    local blob
    blob="${PBC_OS_ID} ${PBC_OS_LIKE} ${PBC_OS_VARIANT} ${PBC_OS_IMAGE_ID} ${PBC_OS_PRETTY}"
    blob="${blob,,}"

    # Bazzite identifies itself in ID, IMAGE_ID, or PRETTY_NAME depending on the
    # image generation, so match the substring anywhere rather than trusting one
    # field.
    if [[ "$blob" == *bazzite* ]]; then PBC_IS_BAZZITE=1; else PBC_IS_BAZZITE=0; fi

    if [[ "$PBC_OS_ID" == fedora || "$PBC_OS_LIKE" == *fedora* || "$blob" == *fedora* ]]; then
        PBC_IS_FEDORA_LIKE=1
    else
        PBC_IS_FEDORA_LIKE=0
    fi
}

detect_atomic() {
    PBC_IS_ATOMIC=0
    # The most reliable signal that we are on an ostree/atomic system.
    if [[ -f /run/ostree-booted ]]; then PBC_IS_ATOMIC=1; fi
    # rpm-ostree present and responsive is corroborating evidence.
    if [[ "$PBC_IS_ATOMIC" == 0 ]] && have rpm-ostree; then
        if rpm-ostree status >/dev/null 2>&1; then PBC_IS_ATOMIC=1; fi
    fi
    if [[ "$PBC_IS_ATOMIC" == 1 && "${PBC_IS_FEDORA_LIKE:-0}" == 1 ]]; then
        PBC_IS_FEDORA_ATOMIC=1
    else
        PBC_IS_FEDORA_ATOMIC=0
    fi
}

# detect_form_factor — handheld vs desktop, used to choose Game-Mode-friendly
# defaults. Best-effort; reports "unknown" rather than guessing wrong.
detect_form_factor() {
    PBC_FORM_FACTOR="unknown"; PBC_HANDHELD_MODEL=""
    local vendor="" product=""
    [[ -r /sys/class/dmi/id/sys_vendor   ]] && vendor="$(< /sys/class/dmi/id/sys_vendor)"
    [[ -r /sys/class/dmi/id/product_name ]] && product="$(< /sys/class/dmi/id/product_name)"
    local key="${vendor} ${product}"

    # Known handhelds. Valve Steam Deck = Jupiter (LCD) / Galileo (OLED).
    case "${key,,}" in
        *valve*|*jupiter*|*galileo*)        PBC_FORM_FACTOR="handheld"; PBC_HANDHELD_MODEL="$(trim "$key")" ;;
        *"rog ally"*|*"rc71l"*|*"rc72la"*)  PBC_FORM_FACTOR="handheld"; PBC_HANDHELD_MODEL="$(trim "$key")" ;;
        *"aya neo"*|*ayaneo*|*"loki"*)      PBC_FORM_FACTOR="handheld"; PBC_HANDHELD_MODEL="$(trim "$key")" ;;
        *"legion go"*|*"83e1"*|*"83l3"*)    PBC_FORM_FACTOR="handheld"; PBC_HANDHELD_MODEL="$(trim "$key")" ;;
        *)
            # Chassis type 30/31/32 = tablet/handheld-ish; otherwise assume desktop
            # only when we actually have DMI data to look at.
            if [[ -n "$vendor$product" ]]; then PBC_FORM_FACTOR="desktop"; fi
            ;;
    esac
}

# detect_rom_library — look for an existing EmuDeck / ES-DE ROM library so we
# can reuse it instead of creating a parallel ~/ROMs tree. Sets PBC_ROM_LIBRARY
# to the first match (or empty). Read-only; never moves anything.
detect_rom_library() {
    PBC_ROM_LIBRARY=""
    local c g
    local candidates=("$HOME/Emulation/roms" "$HOME/Emulation/ROMs")
    # EmuDeck on SD cards / external drives mounts under /run/media/...
    for g in /run/media/*/*/Emulation/roms /run/media/*/Emulation/roms; do
        [[ -d "$g" ]] && candidates+=("$g")
    done
    for c in "${candidates[@]}"; do
        if [[ -d "$c" ]]; then PBC_ROM_LIBRARY="$c"; return 0; fi
    done
    return 1
}

# detect_all — run every detector. Safe to call multiple times.
detect_all() { detect_os; detect_atomic; detect_form_factor; }

# os_summary_line — single human-readable line for logs/summary.
os_summary_line() {
    local label="${PBC_OS_PRETTY:-unknown OS}"
    local tags=()
    [[ "${PBC_IS_BAZZITE:-0}" == 1 ]]       && tags+=("Bazzite")
    [[ "${PBC_IS_FEDORA_ATOMIC:-0}" == 1 ]] && tags+=("Fedora-Atomic")
    [[ "${PBC_IS_ATOMIC:-0}" == 1 ]]        && tags+=("ostree")
    if [[ "${PBC_FORM_FACTOR:-unknown}" != unknown ]]; then
        if [[ -n "${PBC_HANDHELD_MODEL:-}" ]]; then
            tags+=("${PBC_FORM_FACTOR}:${PBC_HANDHELD_MODEL}")
        else
            tags+=("${PBC_FORM_FACTOR}")
        fi
    fi
    local t=""; [[ ${#tags[@]} -gt 0 ]] && t=" [${tags[*]}]"
    printf '%s%s' "$label" "$t"
}
