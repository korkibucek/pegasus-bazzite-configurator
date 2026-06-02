#!/usr/bin/env bash
# run-tests.sh — dependency-free unit tests for the pure functions. Runs on the
# dev host and inside the Fedora smoke container. No real OS state is touched.
set -uo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd)"
LIB="$REPO_ROOT/scripts/lib"
export PBC_SYSTEMS_DIR="$REPO_ROOT/config/systems"
export NO_COLOR=1 QUIET=1

# Source under test.
# shellcheck source=scripts/lib/common.sh
source "$LIB/common.sh"
# shellcheck source=scripts/lib/detect.sh
source "$LIB/detect.sh"
# shellcheck source=scripts/lib/emulators.sh
source "$LIB/emulators.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB/backup.sh"
# shellcheck source=scripts/lib/pegasus.sh
source "$LIB/pegasus.sh"

PASS=0; FAIL=0
check() { # check "desc" "expected" "actual"
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); # printf 'ok   %s\n' "$1"
    else FAIL=$((FAIL+1)); printf 'FAIL %s\n  expected: [%s]\n  actual:   [%s]\n' "$1" "$2" "$3"; fi
}
check_contains() { # desc haystack needle
    if [[ "$2" == *"$3"* ]]; then PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); printf 'FAIL %s\n  [%s] does not contain [%s]\n' "$1" "$2" "$3"; fi
}
check_rc() { # desc expected_rc actual_rc
    if [[ "$2" == "$3" ]]; then PASS=$((PASS+1));
    else FAIL=$((FAIL+1)); printf 'FAIL %s\n  expected rc %s, got %s\n' "$1" "$2" "$3"; fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- trim -------------------------------------------------------------------
check "trim spaces" "abc" "$(trim '   abc   ')"
check "trim tabs"   "a b" "$(trim $'\t''a b'$'\t')"

# --- _quote_args (space-safe rendering) -------------------------------------
check "quote_args plain"  "a b" "$(_quote_args a b)"
check "quote_args spaces" "'/my ROMs/x'" "$(_quote_args '/my ROMs/x')"

# --- cfg_is_yes -------------------------------------------------------------
cfg_is_yes yes  && r=0 || r=1; check_rc "cfg_is_yes yes" 0 "$r"
cfg_is_yes no   && r=0 || r=1; check_rc "cfg_is_yes no"  1 "$r"
cfg_is_yes TRUE && r=0 || r=1; check_rc "cfg_is_yes TRUE" 0 "$r"

# --- OS detection: Bazzite fixture ------------------------------------------
cat >"$TMP/osr-bazzite" <<'EOF'
NAME="Bazzite"
ID=bazzite
ID_LIKE="fedora"
VARIANT_ID=bazzite-deck
IMAGE_ID=bazzite-deck
PRETTY_NAME="Bazzite (FROM Fedora Silverblue 41)"
EOF
OS_RELEASE_FILE="$TMP/osr-bazzite" detect_os
check "bazzite IS_BAZZITE"     "1" "$PBC_IS_BAZZITE"
check "bazzite IS_FEDORA_LIKE" "1" "$PBC_IS_FEDORA_LIKE"

# --- OS detection: plain Fedora fixture -------------------------------------
cat >"$TMP/osr-fedora" <<'EOF'
NAME="Fedora Linux"
ID=fedora
VERSION_ID=41
PRETTY_NAME="Fedora Linux 41 (Container Image)"
EOF
OS_RELEASE_FILE="$TMP/osr-fedora" detect_os
check "fedora IS_BAZZITE"     "0" "$PBC_IS_BAZZITE"
check "fedora IS_FEDORA_LIKE" "1" "$PBC_IS_FEDORA_LIKE"

# --- OS detection: Ubuntu fixture (the dev host trap) -----------------------
cat >"$TMP/osr-ubuntu" <<'EOF'
NAME="Ubuntu"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
OS_RELEASE_FILE="$TMP/osr-ubuntu" detect_os
check "ubuntu IS_BAZZITE"     "0" "$PBC_IS_BAZZITE"
check "ubuntu IS_FEDORA_LIKE" "0" "$PBC_IS_FEDORA_LIKE"

# --- YAML-subset parser -----------------------------------------------------
# NOTE: no subshells here — check()/check_rc() mutate PASS/FAIL counters, which
# would be lost in a subshell and make the suite's exit code meaningless. We
# instead set the few CFG_* vars each test needs explicitly.
cat >"$TMP/cfg.yaml" <<'EOF'
# comment
rom_root: "/home/deck/My Games"   # inline comment
create_rom_dir: yes
emulators:
  - retroarch
  - dolphin
  - pcsx2
systems: snes, n64, psx
mode: force
EOF
parse_config_file "$TMP/cfg.yaml"
check "yaml scalar w/ spaces+comment" "/home/deck/My Games" "$CFG_ROM_ROOT"
check "yaml block sequence" "retroarch dolphin pcsx2" "$CFG_EMULATORS"
check "yaml inline comma list" "snes n64 psx" "$CFG_SYSTEMS"
check "yaml scalar" "force" "$CFG_MODE"

# --- config_validate --------------------------------------------------------
config_set_defaults; CFG_ROM_ROOT="/abs/path"; CFG_EMULATORS="retroarch dolphin"
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate good config" 0 "$r"
config_set_defaults; CFG_ROM_ROOT="relative/path"
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate rejects relative rom_root" 1 "$r"
config_set_defaults; CFG_EMULATORS="retroarch bogusemu"
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate rejects unknown emulator" 1 "$r"
config_set_defaults  # restore sane defaults for later tests

# --- build_launch_line ------------------------------------------------------
export HOME="/home/tester"
LAUNCH_PREFIX=""
ll="$(build_launch_line retroarch snes9x)"
check_contains "retroarch launch has core path" "$ll" "/home/tester/.var/app/org.libretro.RetroArch/config/retroarch/cores/snes9x_libretro.so"
check_contains "retroarch launch keeps {file.path}" "$ll" '"{file.path}"'
ll2="$(build_launch_line dolphin '')"
check "dolphin launch verbatim" 'flatpak run org.DolphinEmu.dolphin-emu -b -e "{file.path}"' "$ll2"
LAUNCH_PREFIX="flatpak-spawn --host "
ll3="$(build_launch_line pcsx2 '')"
check_contains "flatpak prefix applied" "$ll3" "flatpak-spawn --host flatpak run net.pcsx2.PCSX2"

# --- controller_friendly toggles windowed variant ---------------------------
LAUNCH_PREFIX=""
CFG_CONTROLLER_FRIENDLY=yes
cf="$(build_launch_line duckstation '')"
check "duckstation controller-friendly = fullscreen" 'flatpak run org.duckstation.DuckStation -batch -fullscreen "{file.path}"' "$cf"
CFG_CONTROLLER_FRIENDLY=no
win="$(build_launch_line duckstation '')"
check "duckstation windowed drops -fullscreen" 'flatpak run org.duckstation.DuckStation -batch "{file.path}"' "$win"
# Emulator with no windowed variant falls back to the controller-friendly form.
ppsspp_win="$(build_launch_line ppsspp '')"
check "ppsspp (no windowed variant) falls back" 'flatpak run org.ppsspp.PPSSPP "{file.path}"' "$ppsspp_win"
CFG_CONTROLLER_FRIENDLY=yes  # restore

# --- per-system emulator override -------------------------------------------
config_set_defaults
CFG_SYSTEM_EMULATORS="psx=retroarch:swanstation gamecube=dolphin"
pair="$(resolve_system_emulator psx duckstation '')"
check "override psx emulator" "retroarch" "${pair%%$'\t'*}"
check "override psx core"     "swanstation" "${pair#*$'\t'}"
# Override without a core keeps the system default core.
pair2="$(resolve_system_emulator gamecube dolphin '')"
check "override gamecube emulator" "dolphin" "${pair2%%$'\t'*}"
# A system with no override resolves to its defaults.
pair3="$(resolve_system_emulator snes retroarch snes9x)"
check "no override keeps default emu" "retroarch" "${pair3%%$'\t'*}"
check "no override keeps default core" "snes9x" "${pair3#*$'\t'}"
# Validation: retroarch override without a core for a non-retroarch system fails.
config_set_defaults; CFG_ROM_ROOT="/abs"; CFG_EMULATORS="retroarch dolphin"
CFG_SYSTEM_EMULATORS="gamecube=retroarch"
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate rejects retroarch override w/o core" 1 "$r"
CFG_SYSTEM_EMULATORS="psx=retroarch:swanstation"
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate accepts retroarch override w/ core" 0 "$r"
CFG_SYSTEM_EMULATORS="psx=bogusemu"
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate rejects unknown override emulator" 1 "$r"
config_set_defaults

# --- pegasus_resolve_systems (auto filters by selected emulator) ------------
config_set_defaults; CFG_EMULATORS="dolphin"; CFG_SYSTEMS="auto"
dolphin_systems="$(pegasus_resolve_systems | sort | tr '\n' ' ')"
check "auto systems for dolphin" "gamecube wii " "$dolphin_systems"

# --- write_file always ends files with a single trailing newline ------------
wf="$TMP/wf.txt"
printf 'alpha\nbeta' | write_file "$wf"   # input deliberately lacks trailing \n
last_char="$(tail -c1 "$wf" | od -An -c | tr -d ' ')"
check "write_file adds trailing newline" '\n' "$last_char"
check "write_file preserves content" "alpha beta" "$(tr '\n' ' ' <"$wf" | sed 's/ $//')"

# --- backup path generation -------------------------------------------------
PBC_STATE_DIR="$TMP/state"; PBC_BACKUP_DIR=""
backup_begin   # sets PBC_BACKUP_DIR in this shell (must NOT be called via $(...))
check_contains "backup dir under state" "$PBC_BACKUP_DIR" "$TMP/state/backups/"
# Idempotent within a run: a second call must not change the dir.
first_dir="$PBC_BACKUP_DIR"; backup_begin
check "backup_begin idempotent" "$first_dir" "$PBC_BACKUP_DIR"

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
