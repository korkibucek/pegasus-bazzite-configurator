# pegasus-bazzite-configurator

Zero-touch configurator that turns a fresh or existing **Bazzite Linux** install
into a working **[Pegasus Frontend](https://pegasus-frontend.org/)** setup with
emulator backends — installed as Flatpaks, configured in user space, with the
ROM-path sandbox permissions that normally trip people up handled for you.

```bash
git clone https://github.com/korkibucek/pegasus-bazzite-configurator.git
cd pegasus-bazzite-configurator
./scripts/deploy.sh                 # interactive
# …or fully unattended:
./scripts/deploy.sh --config config/example-config.yaml --non-interactive
```

Answer a handful of prompts and you end up with Pegasus installed, your chosen
emulators installed, per-system collections generated, and the Flatpak
filesystem permissions set so emulators can actually read your ROMs.

---

## Why this exists

Bazzite is **Fedora Atomic** (Universal Blue, `rpm-ostree`/`bootc`) — an
immutable image-based OS. The usual "apt install / dump files in /usr" playbook
is wrong and can break your system. The right approach is **Flatpak + user-space
config + minimal system mutation**, and a few non-obvious details (cross-sandbox
launching, ROM-path access for sandboxed emulators) have to be exactly right or
the result *looks* configured but doesn't actually launch games. This tool
encodes those details.

## What it does

- **Detects** the platform defensively (`/etc/os-release`, `rpm-ostree`,
  ostree-booted, DMI) — Bazzite vs other Fedora Atomic vs neither, and
  handheld (Steam Deck etc.) vs desktop.
- **Checks prerequisites** (network, flatpak + Flathub, disk, write access,
  existing install state) with clear pass/warn/fail messages.
- **Installs Pegasus Frontend** from Flathub (`org.pegasus_frontend.Pegasus`).
- **Installs the emulators you pick** as Flatpaks and **grants each one access
  to your ROM directory** (`flatpak override --user … --filesystem=…`).
- **Generates Pegasus config**: registers your game directories and writes a
  `metadata.pegasus.txt` per system with the correct, space-safe launch command.
- **Handles cross-sandbox launching**: when Pegasus is itself a Flatpak, launch
  lines use `flatpak-spawn --host` and Pegasus is granted the permission to spawn
  the emulators.
- **Backs up** anything it would overwrite (timestamped, restorable).
- Offers **dry-run**, **non-interactive**, **force-reconfigure**, **logging**,
  a **validation** pass, and a **restore** path.

## Supported platforms

| Platform | Status |
|---|---|
| Bazzite (desktop & handheld/Deck) | Primary target |
| Other Fedora Atomic (Silverblue/Kinoite/Bazzite-like) | Best-effort (`--allow-non-bazzite`) |
| Plain Fedora (container) | Used for smoke testing only — see [docs/BAZZITE_NOTES.md](docs/BAZZITE_NOTES.md) |
| Ubuntu/Debian | **Not supported** as a target (dev host only) |

## Supported emulators

RetroArch, Dolphin, PCSX2, PPSSPP, DuckStation, RPCS3, MAME, melonDS, ScummVM,
Flycast, Cemu (Wii U) and xemu (Xbox) via Flathub, plus Vita3K (PS Vita) via its
official AppImage. See [docs/EMULATOR_SUPPORT.md](docs/EMULATOR_SUPPORT.md) for
the launch templates, the DuckStation licensing caveat, and why Switch emulators
are **not** included by default.

## Quick start

```bash
./scripts/deploy.sh --dry-run        # preview everything, change nothing
./scripts/deploy.sh                  # interactive install
./scripts/validate.sh                # verify the result (pass/fail)
```

Non-interactive / repeatable:

```bash
cp config/example-config.yaml config/local-mydeck.yaml   # edit to taste
./scripts/deploy.sh --config config/local-mydeck.yaml --non-interactive
```

## Tools

Every script supports `--help`, and the state-changing ones support `--dry-run`.

| Script | What it does |
|---|---|
| `scripts/deploy.sh` | Main configurator — detect, install Pegasus + emulators, install cores, generate config. Also `--repair`, `--list-emulators`, `--list-systems`, `--restore`. |
| `scripts/validate.sh` | Post-deploy pass/fail check: installs, sandbox ROM access, metadata, RetroArch cores, BIOS preflight. |
| `scripts/autoscraper.sh` | Scrape box art + metadata with Skyscraper, in an isolated Podman container. |
| `scripts/cleanup.sh` | Hide disc-track / duplicate files from Pegasus (re-syncs `extensions:`; never deletes ROMs/media). |
| `scripts/install-cores.sh` | (Re)install RetroArch libretro cores from the official buildbot. |
| `scripts/add-to-steam.sh` | Add Pegasus to Steam so it launches from Game Mode. |
| `scripts/update.sh` | `flatpak update --user` the managed Pegasus + emulators. |
| `scripts/restore.sh` | Restore Pegasus config from a timestamped backup (`--list` to browse). |
| `scripts/uninstall.sh` | Remove generated config (ROMs preserved); `--remove-flatpaks` also removes the apps. |

## Configuration

Everything is driven by a small YAML file (no `yq` dependency). Every key is
documented inline in [`config/example-config.yaml`](config/example-config.yaml).
Highlights:

| Key | Default | Meaning |
|---|---|---|
| `rom_root` | `~/ROMs` | Root holding per-system ROM folders |
| `pegasus_install` | `flatpak` | `flatpak` \| `appimage` \| `skip` |
| `emulators` | (5 common) | Emulator keys to install |
| `systems` | `auto` | `auto` = systems whose emulator you selected |
| `mode` | `install-missing` | `install-missing` \| `force` (overwrite) |
| `backup` | `yes` | Back up before overwriting |
| `extra_rom_paths` | (none) | Extra mounts/SD cards to grant emulators |
| `reuse_existing_library` | `auto` | Adopt a detected EmuDeck/ES-DE library as `rom_root` |
| `system_emulators` | (none) | Override a system's emulator, e.g. `psx=retroarch:swanstation` |
| `install_cores` | `yes` | Download the libretro cores your RetroArch systems need during deploy |

CLI flags override the config file (`--force`, `--dry-run`, `--non-interactive`,
`--allow-non-bazzite`, `--quiet`, `--verbose`). Run `./scripts/deploy.sh --help`.

## ROM directory layout

```
<rom_root>/
  snes/      metadata.pegasus.txt   media/   <your .sfc files>
  psx/       metadata.pegasus.txt   media/   <your .chd files>
  gamecube/  metadata.pegasus.txt   media/   …
```

Each system folder is registered with Pegasus and contains a generated,
editable `metadata.pegasus.txt`. **No BIOS, ROMs, firmware, or keys are ever
installed** — add your own legally obtained files. See
[docs/PEGASUS_CONFIG.md](docs/PEGASUS_CONFIG.md).

## Testing

```bash
make check          # bash -n + ShellCheck + unit tests (on the dev host)
make smoke-fedora   # run the suite inside a Fedora container (needs podman/docker)
```

The Fedora smoke test catches script/config errors before you touch real
hardware. It explicitly **does not** prove rpm-ostree/Game-Mode/sandbox/runtime
behaviour — those need a real Bazzite machine. See
[docs/TESTING.md](docs/TESTING.md).

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design, data/control flow, decisions
- [docs/BAZZITE_NOTES.md](docs/BAZZITE_NOTES.md) — atomic OS, Flatpak sandbox, Game Mode, SD cards
- [docs/PEGASUS_CONFIG.md](docs/PEGASUS_CONFIG.md) — config/metadata structure, adding a system
- [docs/EMULATOR_SUPPORT.md](docs/EMULATOR_SUPPORT.md) — emulators, launch commands, adding one
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common Bazzite/Pegasus/Flatpak problems
- [docs/SCRAPING.md](docs/SCRAPING.md) — scrape artwork/metadata with Skyscraper (Podman)
- [docs/TESTING.md](docs/TESTING.md) — what the container test proves and what it doesn't
- [docs/ROADMAP.md](docs/ROADMAP.md) — release status, known limitations, planned work
- [CHANGELOG.md](CHANGELOG.md) — release history

Contributing? See [CONTRIBUTING.md](CONTRIBUTING.md) for the dev gate (`make
check` / `make smoke-fedora`), how to add a system or emulator, and branch/PR
conventions.

## Known limitations

- RetroArch cores are downloaded for you by default (`install_cores: yes`); set
  it to `no` to manage them yourself via RetroArch's Core Downloader.
- BIOS/firmware for PCSX2/RPCS3/DuckStation/etc. must be provided by you
  (`validate.sh` flags where they go; nothing copyrighted is ever installed).
- Multi-disc games (e.g. Final Fantasy VII Disc 1/2/3) currently show one entry
  per disc; `.m3u` playlist grouping is a planned enhancement (see
  [docs/ROADMAP.md](docs/ROADMAP.md)).
- ScummVM and MAME need per-game/per-set setup beyond a generic launch line.
- Vita3K is experimental and PS Vita support is best-effort.

See [docs/ROADMAP.md](docs/ROADMAP.md) for status and planned work.

## License

Licensed under the **Apache License, Version 2.0** — see [LICENSE](LICENSE) and
[NOTICE](NOTICE). Copyright 2026 Robert Morgan.
