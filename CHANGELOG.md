# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses date-based
pre-1.0 development entries until the first tagged release.

## [Unreleased]

### Changed
- Test/CI hardening (#27): smoke harness defaults to **Fedora 44** (Bazzite 44's
  base) and accepts any image via `PBC_SMOKE_IMAGE` / a full image ref (so a
  trusted Bazzite image can be used); CI runs the smoke suite across a Fedora
  42/43/44 matrix and now lints the `lib/*.sh` modules directly.
- `controller_friendly` now actually affects generated launch lines: `no` emits
  windowed/desktop variants for DuckStation/PCSX2/Dolphin/RPCS3 (default `yes`
  output is unchanged). `target=gamemode` now surfaces a clear outstanding action
  on how to add Pegasus to Steam for Game Mode (#16).

### Added
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
