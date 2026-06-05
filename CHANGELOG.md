# Changelog

All notable changes to this project are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/) and this project adheres to
[Semantic Versioning](https://semver.org/).

## [Unreleased]

_Nothing yet._

## [1.0.0] - 2026-06-05

First release. Validated end-to-end on real Bazzite (Bazzite 44, desktop and via
the live deployment used during development).

### Added

**Core**
- Deployment engine (`scripts/deploy.sh`): interactive and non-interactive
  (`--config`) modes, `--dry-run`, `--force`, `--repair`, `--list-emulators`,
  `--list-systems`, `--restore`, structured logging, timestamped backups, and a
  final deployment summary.
- Defensive platform detection (Bazzite / Fedora Atomic / handheld vs desktop)
  and prerequisite checks (network, flatpak + Flathub, disk, write access,
  existing install state).
- Pegasus Frontend install via Flathub with cross-sandbox launch handling
  (`flatpak-spawn --host` + `--talk-name=org.freedesktop.Flatpak`), and
  per-emulator ROM-path `flatpak override` permissions.
- Data-driven system catalog (`config/systems/*.conf`) and generated, space-safe
  `metadata.pegasus.txt` per system; dependency-free YAML-subset config parser
  (no `yq`).

**Emulators & systems**
- Emulator catalog: RetroArch, Dolphin, PCSX2, PPSSPP, DuckStation, RPCS3, MAME,
  melonDS, ScummVM, Flycast, Cemu (Wii U), xemu (Xbox), and Vita3K (PS Vita, via
  its official AppImage — not on Flathub). Switch emulators are intentionally
  excluded (documented).
- Per-system emulator overrides via `system_emulators` (`shortname=emulator[:core]`)
  — e.g. the DuckStation → SwanStation fallback as a one-liner.
- ES-DE/EmuDeck library reuse (`reuse_existing_library`): detect `~/Emulation/roms`
  (incl. SD cards) and reconcile folder names (e.g. ES-DE `gc`) without moving ROMs.

**Helper tools**
- `scripts/install-cores.sh` and built-in `install_cores` — download the libretro
  cores RetroArch systems need from the official buildbot (HTTPS, zip-validated).
- `scripts/autoscraper.sh` — scrape box art + metadata with Skyscraper in an
  isolated Podman container (Bazzite-friendly; nothing layered onto the host).
- `scripts/cleanup.sh` — hide disc-track/duplicate files from Pegasus by
  re-syncing collection `extensions:`; never deletes ROMs/media.
- `scripts/add-to-steam.sh` — add Pegasus to Steam for Game Mode (safe binary
  `shortcuts.vdf` editing).
- `scripts/update.sh`, `scripts/restore.sh`, `scripts/uninstall.sh` — lifecycle.
- `scripts/validate.sh` — post-deploy pass/fail check incl. Flatpak ROM access,
  RetroArch core presence, and a BIOS/firmware preflight (never fetches BIOS).

**Project**
- Apache-2.0 `LICENSE` + `NOTICE`; `CONTRIBUTING.md`; full `docs/` set.
- Fedora-container smoke test (`make smoke-fedora`), unit-test suite
  (`tests/run-tests.sh`), ShellCheck-clean scripts, CI (ShellCheck + unit +
  Fedora 42/43/44 matrix), and issue/PR templates.

### Changed
- RetroArch core installation is built into `deploy.sh` via `install_cores`
  (default `yes`); shared logic in `scripts/lib/cores.sh`.
- `controller_friendly` affects launch lines (`no` → windowed variants for
  DuckStation/PCSX2/Dolphin/RPCS3); `target=gamemode` surfaces a "add to Steam"
  action.
- CI smoke harness defaults to **Fedora 44** and accepts any image via
  `PBC_SMOKE_IMAGE`; runs a Fedora 42/43/44 matrix and lints `lib/*.sh` directly.

### Fixed
- **Bazzite blocker:** all `--user` Flatpak installs failed because Bazzite ships
  flathub only as a filtered *system* remote — `ensure_flathub` is now scope-aware
  and adds a `--user` remote when missing.
- Vita3K install always failed (it isn't on Flathub) — now installed via its
  official AppImage instead.
- Scraped art didn't appear in Pegasus — pass Skyscraper `--flags unattend`
  (overwrite the deploy metadata without prompting) and mount the ROM dir at its
  real host path so `file:`/`assets.*` paths are host-valid; added
  `--generate-only`.
- PS1 disc-track `.bin` files showed as duplicate games — `psx` `extensions:` no
  longer list `bin`/`img`; `cleanup.sh` re-syncs existing libraries.
- `pegasus_install: skip` now still configures an already-installed Pegasus
  flatpak (launch prefix + ROM access).
- Flatpak install failures surface the real error (`run_cmd_capture`).
- Non-writable `rom_root` gives actionable suggestions + an interactive re-prompt.
- `write_file` writes exactly one trailing newline (fixed `game_dirs.txt` gluing).
- `backup_begin` no longer allocates its dir in a subshell; `--force` is no longer
  overridden by the config file; `print_summary` no longer trips the `set -e` ERR
  trap on real runs.

[Unreleased]: https://github.com/korkibucek/pegasus-bazzite-configurator/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/korkibucek/pegasus-bazzite-configurator/releases/tag/v1.0.0
