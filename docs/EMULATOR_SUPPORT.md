# Emulator support

All emulators are installed from **Flathub** at `--user` scope and granted
filesystem access to your ROM root. Catalog lives in
`scripts/lib/emulators.sh`; default per-system mapping lives in
`config/systems/*.conf`.

## Supported emulators

| Key | Emulator | Flathub id | Default systems | Launch (file portion) |
|---|---|---|---|---|
| `retroarch` | RetroArch | `org.libretro.RetroArch` | NES, SNES, N64, GB/GBC/GBA, Genesis, SMS, PC Engine, Atari 2600, Dreamcast | `-L "<core>.so" "{file.path}"` |
| `dolphin` | Dolphin | `org.DolphinEmu.dolphin-emu` | GameCube, Wii | `-b -e "{file.path}"` |
| `pcsx2` | PCSX2 | `net.pcsx2.PCSX2` | PS2 | `-batch "{file.path}"` |
| `ppsspp` | PPSSPP | `org.ppsspp.PPSSPP` | PSP | `"{file.path}"` |
| `duckstation` | DuckStation | `org.duckstation.DuckStation` | PS1 | `-batch -fullscreen "{file.path}"` |
| `rpcs3` | RPCS3 | `net.rpcs3.RPCS3` | PS3 | `--no-gui "{file.path}"` |
| `mame` | MAME | `org.mamedev.MAME` | Arcade | `-rompath "{file.dir}" "{file.basename}"` |
| `melonds` | melonDS | `net.kuribo64.melonDS` | Nintendo DS | `"{file.path}"` |
| `scummvm` | ScummVM | `org.scummvm.ScummVM` | Adventure games | `-p "{file.dir}" -f "{file.basename}"` |

When Pegasus is a Flatpak, every launch line is additionally prefixed with
`flatpak-spawn --host ` so the sandboxed Pegasus can start the host Flatpak.

### `controller_friendly` (launch flags)

`controller_friendly: yes` (default) uses the fullscreen / batch / no-GUI form
shown above — ideal for a couch/handheld controller experience. Setting it to
`no` emits a windowed/desktop variant for emulators where it makes a difference:

| Emulator | controller-friendly (`yes`) | windowed (`no`) |
|---|---|---|
| DuckStation | `-batch -fullscreen` | `-batch` |
| PCSX2 | `-batch` | (no flags — opens GUI) |
| Dolphin | `-b -e` | `-e` (keeps GUI) |
| RPCS3 | `--no-gui` | (shows GUI) |

Emulators without a windowed variant (RetroArch, PPSSPP, MAME, melonDS, ScummVM)
use the same line either way; adjust fullscreen behaviour in their own settings.

## RetroArch cores are not bundled

The Flathub RetroArch ships **without cores**. Install them once:

> RetroArch → **Online Updater → Core Downloader** → pick the core named in each
> system's metadata comment (e.g. `snes9x`, `mgba`, `mupen64plus_next`).

Cores install to
`~/.var/app/org.libretro.RetroArch/config/retroarch/cores/<core>_libretro.so`,
which is exactly the path the generated `launch:` line references.

## BIOS / firmware (you must provide)

Several emulators need files this tool will **never** supply:

- **PCSX2** — PS2 BIOS (configure in PCSX2 → Settings → BIOS).
- **DuckStation** — PS1 BIOS.
- **RPCS3** — PS3 firmware (RPCS3 → Install Firmware).
- Some RetroArch cores (PS1, PC Engine CD, etc.) need system BIOS files in
  `~/.var/app/org.libretro.RetroArch/config/retroarch/system/`.

Use only legally obtained dumps from hardware you own.

## Caveats by emulator

- **DuckStation**: its license and Flathub availability have changed over time.
  If `flatpak install … org.duckstation.DuckStation` fails, use **SwanStation**
  (a libretro PS1 core) via RetroArch for the `psx` system instead. Easiest way,
  no file edits — add to your config:
  `system_emulators: psx=retroarch:swanstation` (see PEGASUS_CONFIG.md). Or edit
  `psx.conf` to `SYS_EMULATOR="retroarch"` / `SYS_RA_CORE="swanstation"`.
- **MAME**: launches by ROM short-name and requires version-correct ROM sets
  matching your MAME version. The generated launch passes the rompath and base
  name; arcade is inherently fiddly.
- **ScummVM**: identifies games rather than running a raw file. Recommended
  workflow: create one small `*.scummvm` file per game whose contents are the
  ScummVM game id (e.g. `monkey2`), or add games inside ScummVM and let it manage
  them. The generic launch line is a starting point, not a guarantee.
- **RPCS3 / PCSX2**: demanding; best on desktop hardware, usable on newer
  handhelds for lighter titles.

## Switch emulators — deliberately excluded

Switch emulators (e.g. yuzu, Ryujinx) are **not** included by default:

- yuzu was discontinued following litigation; Ryujinx development also ceased and
  it was removed from Flathub. There is no maintained, Flathub-installable option
  to target reliably.
- Switch emulation depends on user-supplied keys/firmware and sits in a legally
  contested area.

If a maintained, legitimately distributable option exists for your setup, you can
add it yourself: add a catalog entry in `emulators.sh` and a `config/systems/`
definition. This tool will never bundle keys or firmware.

## Adding another emulator

1. Add to the catalog in `scripts/lib/emulators.sh`:
   ```sh
   EMU_NAME[flycast]="Flycast (Dreamcast, standalone)"
   EMU_ID[flycast]="org.flycast.Flycast"
   EMU_LAUNCH[flycast]='flatpak run org.flycast.Flycast "{file.path}"'
   # optional: EMU_NOTE[flycast]="…"
   EMU_ORDER+=(flycast)
   ```
2. Point a system at it: set `SYS_EMULATOR="flycast"` in the relevant
   `config/systems/*.conf`.
3. Re-run `./scripts/deploy.sh` and `./scripts/validate.sh`.
