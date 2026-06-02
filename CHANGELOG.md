# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project uses date-based
pre-1.0 development entries until the first tagged release.

## [Unreleased]

### Added
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
