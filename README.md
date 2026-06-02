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

RetroArch, Dolphin, PCSX2, PPSSPP, DuckStation, RPCS3, MAME, melonDS, ScummVM —
all via Flathub. See [docs/EMULATOR_SUPPORT.md](docs/EMULATOR_SUPPORT.md) for the
launch templates, the DuckStation licensing caveat, and why Switch emulators are
**not** included by default.

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

Undo:

```bash
./scripts/restore.sh --list          # show backups
./scripts/restore.sh                 # restore the most recent backup
```

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
- [docs/TESTING.md](docs/TESTING.md) — what the container test proves and what it doesn't

## Known limitations

- Final runtime validation (actually launching games) requires a real Bazzite
  machine; the dev host / container cannot prove it.
- RetroArch cores are not bundled by Flathub — install them once via RetroArch's
  Core Downloader (each system's metadata documents the expected core).
- BIOS/firmware for PCSX2/RPCS3/etc. must be provided by you.
- ScummVM and MAME need per-game/per-set setup beyond a generic launch line.

## License

No license has been specified for this repository yet. Until one is added, no
usage rights are granted beyond viewing. Open an issue if you intend to use it.
