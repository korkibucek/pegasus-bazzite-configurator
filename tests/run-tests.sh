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
# shellcheck source=scripts/lib/prereq.sh
source "$LIB/prereq.sh"
# shellcheck source=scripts/lib/config.sh
source "$LIB/config.sh"
# shellcheck source=scripts/lib/backup.sh
source "$LIB/backup.sh"
# shellcheck source=scripts/lib/pegasus.sh
source "$LIB/pegasus.sh"
# shellcheck source=scripts/lib/cores.sh
source "$LIB/cores.sh"

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

# --- #44: scope-aware flathub detection (user scope) ------------------------
# Stub `flatpak` to simulate user-scope remotes.
flatpak() { case "$*" in "remotes --user --columns=name") printf '%s\n' "${FAKE_USER_REMOTES:-}";; *) return 0;; esac; }
FAKE_USER_REMOTES="flathub"
flathub_user_remote_present && r=0 || r=1; check_rc "flathub user remote detected when present" 0 "$r"
FAKE_USER_REMOTES=""    # e.g. Bazzite: only a SYSTEM flathub, none at user scope
flathub_user_remote_present && r=0 || r=1; check_rc "flathub user remote absent (Bazzite case)" 1 "$r"
unset -f flatpak; unset FAKE_USER_REMOTES

# --- #45: run_cmd_capture surfaces the real error + returns the exit code ----
LOG_FILE="$TMP/rcc.log"; : >"$LOG_FILE"
run_cmd_capture bash -c 'echo boom-the-real-error >&2; exit 7' && rc=0 || rc=$?
check_rc "run_cmd_capture propagates exit code" 7 "$rc"
grep -q "boom-the-real-error" "$LOG_FILE" && r=0 || r=1
check_rc "run_cmd_capture logs the real error" 0 "$r"
LOG_FILE=""

# --- #46: ROM-root writability helpers --------------------------------------
HOME="$TMP/home46"; mkdir -p "$HOME"
check_contains "rom_root_suggestions includes \$HOME/ROMs" "$(rom_root_suggestions)" "$TMP/home46/ROMs"
mkdir -p "$TMP/writable"
path_is_writable "$TMP/writable/new/sub" && r=0 || r=1   # nearest existing parent is writable
check_rc "path_is_writable true for writable tree" 0 "$r"
if [[ "$(id -u)" -ne 0 ]]; then
    ro="$TMP/ro"; mkdir -p "$ro"; chmod 555 "$ro"
    path_is_writable "$ro/x" && r=0 || r=1; check_rc "path_is_writable false for read-only dir" 1 "$r"
    chmod 755 "$ro"
fi

# --- steam_shortcuts.py binary VDF round-trip (#22) -------------------------
if have python3; then
    python3 "$REPO_ROOT/scripts/lib/steam_shortcuts.py" selftest >/dev/null 2>&1 && r=0 || r=1
    check_rc "steam_shortcuts.py selftest (binary VDF round-trip)" 0 "$r"
else
    printf 'skip steam_shortcuts selftest (no python3)\n'
fi

# --- RetroArch core URLs (#24) ----------------------------------------------
HOME="/home/tester"
check "ra_core_url snes9x" "https://buildbot.libretro.com/nightly/linux/x86_64/latest/snes9x_libretro.so.zip" "$(ra_core_url snes9x)"
check "ra_core_dir under HOME" "/home/tester/.var/app/org.libretro.RetroArch/config/retroarch/cores" "$(ra_core_dir)"
check_contains "ra_core_url is https" "$(ra_core_url mgba)" "https://"
check "ra_core_file path" "/home/tester/.var/app/org.libretro.RetroArch/config/retroarch/cores/snes9x_libretro.so" "$(ra_core_file snes9x)"
# cores_collect: unique cores for the configured RetroArch systems (honours overrides)
config_set_defaults; CFG_EMULATORS="retroarch"; CFG_SYSTEMS="snes n64 psx"; CFG_SYSTEM_EMULATORS="psx=retroarch:swanstation"
cores_out="$(cores_collect | sort | tr '\n' ' ')"
check "cores_collect maps systems->cores" "mupen64plus_next snes9x swanstation " "$cores_out"
# install_cores config validation
config_set_defaults; CFG_INSTALL_CORES=maybe
config_validate >/dev/null 2>&1 && r=0 || r=1; check_rc "validate rejects bad install_cores" 1 "$r"
config_set_defaults

# --- expanded catalog (#25) -------------------------------------------------
for e in flycast cemu xemu; do
    emu_exists "$e" && r=0 || r=1; check_rc "emulator '$e' in catalog" 0 "$r"
done
# #54: Vita3K is not on Flathub — supported via its official AppImage.
emu_exists vita3k && r=0 || r=1; check_rc "vita3k in catalog" 0 "$r"
emu_is_appimage vita3k && r=0 || r=1; check_rc "vita3k is an AppImage emulator" 0 "$r"
case " ${EMU_ORDER[*]} " in *" vita3k "*) check "vita3k offered in EMU_ORDER" "present" "present";; *) check "vita3k offered in EMU_ORDER" "present" "ABSENT";; esac
HOME="/home/tester"
check "vita3k appimage path" "/home/tester/Applications/Vita3K.AppImage" "$(emu_appimage_path vita3k)"
check_contains "vita3k appimage url is official github https" "$(emu_appimage_url vita3k)" "https://github.com/Vita3K/Vita3K/releases"
# launch line resolves to the AppImage path (no flatpak)
LAUNCH_PREFIX=""; ll_vita="$(build_launch_line vita3k '')"
check "vita3k launch uses AppImage path" '"/home/tester/Applications/Vita3K.AppImage" "{file.path}"' "$ll_vita"
# emu_install dry-run reports it as installed (download previewed), not unavailable
DRY_RUN=1; declare -ga PBC_EMU_INSTALLED=() PBC_EMU_SKIPPED=() PBC_EMU_FAILED=() PBC_EMU_UNAVAILABLE=()
emu_install vita3k >/dev/null 2>&1 && r=0 || r=1; check_rc "emu_install vita3k (dry-run) success" 0 "$r"
check "vita3k recorded installed (dry-run)" "vita3k" "${PBC_EMU_INSTALLED[*]}"
DRY_RUN=0
config_set_defaults; CFG_EMULATORS="retroarch"; CFG_SYSTEMS="auto"
auto_ra="$(pegasus_resolve_systems | sort | tr '\n' ' ')"
check_contains "saturn auto-included for retroarch" "$auto_ra" "saturn"
check_contains "neogeo auto-included for retroarch" "$auto_ra" "neogeo"
# Standalone-only systems must NOT appear when only retroarch is selected.
case " $auto_ra " in *" wiiu "*) check "wiiu excluded w/o cemu" "excluded" "INCLUDED";; *) check "wiiu excluded w/o cemu" "excluded" "excluded";; esac
config_set_defaults; CFG_EMULATORS="cemu"; CFG_SYSTEMS="auto"
auto_cemu="$(pegasus_resolve_systems | tr '\n' ' ')"
check_contains "wiiu auto-included for cemu" "$auto_cemu" "wiiu"
config_set_defaults

# --- catalog listings (--list-emulators / --list-systems) -------------------
emu_list_out="$(emu_catalog_list)"
check_contains "emu_catalog_list has header" "$emu_list_out" "FLATHUB ID"
check_contains "emu_catalog_list lists retroarch" "$emu_list_out" "org.libretro.RetroArch"
check "emu_catalog_list row count == catalog+header" "$((${#EMU_ORDER[@]} + 1))" "$(printf '%s\n' "$emu_list_out" | grep -c .)"
sys_list_out="$(pegasus_systems_list)"
check_contains "pegasus_systems_list has header" "$sys_list_out" "SHORTNAME"
check_contains "pegasus_systems_list lists snes" "$sys_list_out" "snes"

# --- emu_bios_dir (BIOS preflight paths) -------------------------------------
HOME="/home/tester"
check "bios dir pcsx2 expands HOME" "/home/tester/.var/app/net.pcsx2.PCSX2/config/PCSX2/bios" "$(emu_bios_dir pcsx2)"
emu_bios_dir dolphin >/dev/null 2>&1 && r=0 || r=1
check_rc "dolphin needs no BIOS dir" 1 "$r"
emu_bios_dir retroarch >/dev/null 2>&1 && r=0 || r=1
check_rc "retroarch has a system/ dir" 0 "$r"

# --- detect_rom_library (EmuDeck/ES-DE reuse) -------------------------------
lib_home="$TMP/emuhome"; mkdir -p "$lib_home/Emulation/roms"
HOME="$lib_home" detect_rom_library && r=0 || r=1
check_rc "detect_rom_library finds ~/Emulation/roms" 0 "$r"
check "detect_rom_library path" "$lib_home/Emulation/roms" "$PBC_ROM_LIBRARY"
no_home="$TMP/nolib"; mkdir -p "$no_home"
HOME="$no_home" detect_rom_library && r=0 || r=1
check_rc "detect_rom_library absent => non-zero" 1 "$r"

# --- resolve_system_dirname (folder aliases) --------------------------------
CFG_ROM_ROOT="$TMP/lib"; mkdir -p "$CFG_ROM_ROOT/gc" "$CFG_ROM_ROOT/snes"
check "alias: existing gc used for gamecube" "gc" "$(resolve_system_dirname gamecube gamecube)"
check "default used when dir exists" "snes" "$(resolve_system_dirname snes snes)"
check "fresh tree falls back to default" "psp" "$(resolve_system_dirname psp psp)"
config_set_defaults

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

# --- #48: pegasus_install=skip still configures an existing flatpak Pegasus --
DRY_RUN=1
flatpak() { return 0; }   # stub: pretend Pegasus flatpak is installed
config_set_defaults; CFG_PEGASUS_INSTALL=skip; CFG_ROM_ROOT="$TMP/roms48"; CFG_EXTRA_ROM_PATHS=""
LAUNCH_PREFIX=""; PBC_PEGASUS_IS_FLATPAK=0
pegasus_install >/dev/null 2>&1
check "skip+existing-flatpak sets IS_FLATPAK" "1" "$PBC_PEGASUS_IS_FLATPAK"
check_contains "skip+existing-flatpak sets spawn prefix" "$LAUNCH_PREFIX" "flatpak-spawn --host"
flatpak() { return 1; }    # stub: no Pegasus flatpak (native/none)
config_set_defaults; CFG_PEGASUS_INSTALL=skip; LAUNCH_PREFIX=""; PBC_PEGASUS_IS_FLATPAK=0
pegasus_install >/dev/null 2>&1
check "skip+no-flatpak leaves prefix empty" "" "$LAUNCH_PREFIX"
unset -f flatpak; DRY_RUN=0; config_set_defaults

# --- #64: disc-track extensions + cleanup.sh --------------------------------
# psx must NOT list bin/img (they are disc tracks referenced by the .cue);
# megadrive MUST keep bin (it is a whole cartridge ROM).
psx_ext="$(_sys_field psx SYS_EXTENSIONS)"
if [[ "$psx_ext" == *bin* ]]; then check "psx excludes bin" "no-bin" "HAS-bin"; else check "psx excludes bin" "no-bin" "no-bin"; fi
if [[ "$psx_ext" == *img* ]]; then check "psx excludes img" "no-img" "HAS-img"; else check "psx excludes img" "no-img" "no-img"; fi
check_contains "megadrive keeps bin (cartridge)" "$(_sys_field megadrive SYS_EXTENSIONS)" "bin"
# cleanup.sh re-syncs the extensions line, preserving everything else.
cl="$TMP/cleanroms/psx"; mkdir -p "$cl"
printf 'collection: Sony PlayStation\nshortname: psx\nlaunch: x "{file.path}"\nextensions: cue, bin, chd, pbp, m3u, img, ecm\n\ngame: Tomb Raider\nfile: /x/Tomb Raider.cue\n' > "$cl/metadata.pegasus.txt"
HOME="$TMP/cleanhome" "$REPO_ROOT/scripts/cleanup.sh" --roms "$TMP/cleanroms" --system psx -y >/dev/null 2>&1
new_ext="$(grep '^extensions:' "$cl/metadata.pegasus.txt")"
check "cleanup removes bin/img from extensions" "extensions: cue, chd, pbp, m3u, ecm" "$new_ext"
grep -q '^game: Tomb Raider' "$cl/metadata.pegasus.txt" && r=0 || r=1
check_rc "cleanup preserves scraped game entries" 0 "$r"

# --- summary ----------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
