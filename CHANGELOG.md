# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses date-based
pre-1.0 development entries until the first tagged release.

## [Unreleased]

### Changed
- RetroArch core installation is now built into `deploy.sh` via the
  `install_cores` config option (default `yes`): once RetroArch is installed,
  deploy fetches the cores the configured systems need. Logic extracted to a
  shared `scripts/lib/cores.sh` used by both `deploy.sh` and the standalone
  `install-cores.sh`. Dry-run previews cores/URLs; downloads are skipped unless
  RetroArch is present (#52).
- Test/CI hardening (#27): smoke harness defaults to **Fedora 44** (Bazzite 44's
  base) and accepts any image via `PBC_SMOKE_IMAGE` / a full image ref (so a
  trusted Bazzite image can be used); CI runs the smoke suite across a Fedora
  42/43/44 matrix and now lints the `lib/*.sh` modules directly.
- `controller_friendly` now actually affects generated launch lines: `no` emits
  windowed/desktop variants for DuckStation/PCSX2/Dolphin/RPCS3 (default `yes`
  output is unchanged). `target=gamemode` now surfaces a clear outstanding action
  on how to add Pegasus to Steam for Game Mode (#16).

### Added
- `scripts/autoscraper.sh` (#56) — scrape box art + metadata for your Pegasus
  collections with Skyscraper, built/run in an isolated Podman container
  (Bazzite-friendly; nothing layered onto the host). Contributed by @korkibucek,
  then brought to project standards: `#!/usr/bin/env bash` + strict mode, lib
  logging/colors/prompts, `--config`/`--roms`/`--system`/`--user`/`--rebuild`/
  `--dry-run`/`-y`/`--help`, dry-run-aware podman, no hardcoded ROM path (defaults
  to the config/EmuDeck library/`$HOME/ROMs`). Documented in docs/SCRAPING.md;
  added to lint + smoke coverage.
- Vita3K (PS Vita) support via its **official AppImage** (#54): Vita3K isn't on
  Flathub, so it's now installed by downloading `Vita3K-<arch>.AppImage` (HTTPS,
  ELF-verified, `chmod +x`) to `~/Applications/`. Adds a general AppImage-backed
  emulator path (`EMU_APPIMAGE`); AppImages run on the host (no sandbox, direct
  ROM access). Restores the `vita` system. Supersedes the #50 stop-gap that
  marked Vita3K unavailable.
- `LICENSE` (Apache-2.0) + `NOTICE`; README license section updated (#39).
- `CONTRIBUTING.md` — developer guide: repo layout, local dev gate, how to add a
  system/emulator, branch/PR conventions, and the hardware-validation boundary;
  linked from README (#38).
- RetroArch core-presence check in `validate.sh` (#40): per configured RetroArch
  system, WARNs (never fails) when its `<core>_libretro.so` is missing, with the
  exact path and the install command — catching the common "Failed to load core".
- `scripts/add-to-steam.sh` (#22): opt-in helper that adds Pegasus to Steam as a
  non-Steam game for Game Mode. Safely edits the binary `shortcuts.vdf` via a
  stdlib-Python parser (`lib/steam_shortcuts.py`): refuses to run while Steam is
  open, backs up the file first, and appends idempotently without disturbing
  existing shortcuts. Dry-run supported; covered by a round-trip self-test.
- `scripts/install-cores.sh` (#24): opt-in helper that downloads the libretro
  cores required by your selected RetroArch systems from the official libretro
  buildbot (HTTPS, host pinned). Each download is validated as a real ZIP before
  extraction and never executed; existing cores are kept unless `--force` (and
  backed up). Dry-run lists cores + URLs and downloads nothing.
- Expanded catalog (#25): emulators Flycast, Cemu, xemu; systems
  saturn, neogeo, lynx, wonderswan, c64, amiga (RetroArch cores) plus wiiu,
  xbox (standalone). ES-DE folder aliases added (e.g. `atarilynx`). New systems
  auto-include when their emulator is selected.
- Operational flags (#26): `deploy.sh --repair` re-applies only the Flatpak
  sandbox permissions (ROM `--filesystem` access + Pegasus host-spawn), and
  `--list-emulators` / `--list-systems` print the catalogs. List output is
  SIGPIPE-safe (pipe to `head`/`grep` without errors).
- BIOS/firmware preflight in `validate.sh` (#23): WARNs (never fails) per
  selected emulator when the expected BIOS directory is empty/missing, printing
  the exact target path and a hint. Never lists or fetches copyrighted files.
- EmuDeck / ES-DE library reuse (#21): detects an existing `~/Emulation/roms`
  (incl. SD cards) and can adopt it as `rom_root` (`reuse_existing_library:
  auto|yes|no`). Reconciles differing folder names via an alias map (e.g. ES-DE
  `gc` for GameCube) so metadata is written into existing folders rather than
  duplicates. ROMs are never moved/deleted.
- Per-system emulator overrides via the `system_emulators` config key
  (`shortname=emulator[:core]`), so a system can target a different installed
  emulator without editing `config/systems/*.conf`. Validated; auto-includes a
  system when its effective emulator is selected. Makes the DuckStation →
  SwanStation fallback a one-liner (#20).
- `scripts/uninstall.sh` — removes generated metadata/`HOW_TO_ADD_ROMS.txt`,
  deregisters our `game_dirs.txt` entries (keeping user-added ones), and
  optionally `flatpak uninstall --user` the emulators+Pegasus (`--remove-flatpaks`).
  ROM files and media are never touched; everything is backed up first (#17).
- `scripts/update.sh` — `flatpak update --user` for the configured Pegasus +
  emulators (#17).

### Fixed
- Removed Vita3K/`vita` from the catalog — it is **not on Flathub** (only its own
  GitHub/AppImage builds), so its install always failed and left the run in an
  error state. PS Vita is now documented as unsupported by the Flatpak flow (#50).
- `pegasus_install: skip` now still configures an already-installed Pegasus
  flatpak — sets the `flatpak-spawn --host` launch prefix and grants ROM
  `--filesystem` access (without installing) so the generated config works for
  users who manage Pegasus themselves (#48).
- **Blocker on real Bazzite (#44):** all `--user` Flatpak installs failed because
  Bazzite ships flathub only as a filtered *system* remote and `ensure_flathub`
  was scope-blind. It now checks the *user* scope and adds a `--user` flathub
  remote when missing, so emulator/Pegasus installs work out of the box.
- Flatpak install failures now surface the real flatpak error via
  `run_cmd_capture` instead of an opaque "Failed to install X" (#45).
- Non-writable `rom_root` (e.g. `/var/ROMS`) now produces actionable suggestions
  and an interactive re-prompt instead of a dead-end abort (#46).
- `write_file` lost the trailing newline (content came through `$(cat)`), so
  generated files had no final newline and appends to `game_dirs.txt` glued onto
  the last line. Now writes exactly one trailing newline (found via #17).

### Added (earlier)
- Initial deployment engine (`scripts/deploy.sh`) with interactive and
  non-interactive (`--config`) modes, dry-run, force, logging, backup, and a
  final deployment summary.
- Defensive platform detection (Bazzite / Fedora Atomic / handheld vs desktop).
- Prerequisite checks (network, flatpak + Flathub, disk, write access, existing
  install state).
- Emulator catalog (RetroArch, Dolphin, PCSX2, PPSSPP, DuckStation, RPCS3, MAME,
  melonDS, ScummVM) installed via Flathub with per-emulator ROM-path
  `flatpak override` permissions.
- Pegasus Frontend install via Flathub with cross-sandbox launch handling
  (`flatpak-spawn --host` + `--talk-name=org.freedesktop.Flatpak`).
- Data-driven system catalog (`config/systems/*.conf`) and generated
  `metadata.pegasus.txt` per system with space-safe launch commands.
- Timestamped backups + `scripts/restore.sh`.
- `scripts/validate.sh` post-deployment pass/fail checker (including Flatpak ROM
  access verification).
- Dependency-free YAML-subset config parser (no `yq` required).
- Fedora-container smoke test (`scripts/smoke-fedora-container.sh`,
  `make smoke-fedora`) and a unit-test suite (`tests/run-tests.sh`).
- ShellCheck-clean scripts, `Makefile`, CI workflow, issue/PR templates.
- Full documentation set under `docs/`.

### Fixed (during initial development)
- `backup_begin` set its directory in a command-substitution subshell, so the
  parent never recorded the backup path and each file got its own timestamp.
- `--force` was overridden by the config file's `mode`; CLI flags now win.
- `print_summary` ended with `is_dry_run && …`, returning non-zero on real runs
  and spuriously tripping the `set -e` ERR trap (every real run would exit 1).
