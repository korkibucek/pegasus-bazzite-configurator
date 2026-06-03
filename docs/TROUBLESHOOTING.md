# Troubleshooting

Run `./scripts/validate.sh` first — it pinpoints most of the problems below and
prints the exact fix command. Logs are under
`~/.local/share/pegasus-bazzite-configurator/logs/`.

## Pegasus launches the emulator but the game won't load / "file not found"

Almost always a **Flatpak sandbox permission** issue: the emulator can't read
your ROM folder.

```bash
flatpak override --user <emulator-app-id> --filesystem="/path/to/ROMs"
# verify:
flatpak info --show-permissions <emulator-app-id>
```

Re-running `./scripts/deploy.sh` re-applies these overrides for all selected
emulators. For a fast, config-only fix that touches nothing else, use:

```bash
./scripts/deploy.sh --repair --config <your-config>     # add --dry-run to preview
```

If ROMs are on an SD card, add the mount to `extra_rom_paths`.

## Pegasus (Flatpak) won't start emulators at all in Game Mode

A Flatpak Pegasus needs permission to spawn host processes:

```bash
flatpak override --user org.pegasus_frontend.Pegasus --talk-name=org.freedesktop.Flatpak
```

and the launch lines must start with `flatpak-spawn --host` (the tool generates
them this way when it detects a Flatpak Pegasus). If you installed Pegasus as a
Flatpak after generating config with a native Pegasus assumption, re-run with
`--force`.

## `flatpak: command not found`

You're not on Bazzite (Bazzite ships Flatpak). On the dev host this is expected
and dry-run still works. On a real target, install/enable Flatpak first.

## Flathub remote missing

```bash
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
```

The tool does this automatically when installing.

## DuckStation fails to install

Its Flathub availability has fluctuated. Switch the `psx` system to RetroArch +
SwanStation: edit `config/systems/psx.conf` →
`SYS_EMULATOR="retroarch"`, `SYS_RA_CORE="swanstation"`, then re-run with
`--force`. See [EMULATOR_SUPPORT.md](EMULATOR_SUPPORT.md).

## RetroArch says "Failed to load core" / black screen

The core isn't installed. Open RetroArch → **Online Updater → Core Downloader**
and install the core named in the system's `metadata.pegasus.txt` comment. Some
cores also need BIOS files in
`~/.var/app/org.libretro.RetroArch/config/retroarch/system/`.

## Games don't show up in Pegasus

- Confirm the system folder is listed in `game_dirs.txt` (the tool registers it).
- Confirm your ROM file extension matches the `extensions:` line in the system's
  `metadata.pegasus.txt`.
- Restart Pegasus so it rescans.

## Too many duplicate games / disc tracks (.bin) listed

A multi-track disc (common for PS1) is one `.cue` plus many redbook-audio
`.bin` track files — so if the collection's `extensions:` includes `bin`,
Pegasus lists every track as a separate "game" (e.g. ~50 Tomb Raider entries).
The fix is to stop Pegasus *discovering* the track files; the `.bin` files must
stay on disk because the `.cue` references them.

```bash
./scripts/cleanup.sh --config <your-config>      # all systems (add --dry-run to preview)
./scripts/cleanup.sh --roms ~/ROMs --system psx  # just one
```

`cleanup.sh` re-syncs each system's `extensions:` line to the catalog (which
excludes track-only formats like `bin`/`img` for disc systems), backs up the
metadata first, and **never deletes ROMs or media**. It preserves your launch
command and any scraped game entries/artwork. Restart Pegasus afterward.
(Cartridge systems like Mega Drive keep `bin` — there it's a whole ROM.)

## "not detected as Bazzite"

The tool refuses non-Bazzite targets by default. On other Fedora Atomic systems
pass `--allow-non-bazzite`. It will still prefer Flatpak/user-space; behaviour on
non-Bazzite atomic variants is best-effort.

## The script exited with errors but produced config

`log_error` marks the run as failed (exit 1) while still finishing and printing a
summary. Read the summary's "failed" lines and the log. Common cause on a dev
host: emulator installs failed because Flatpak isn't present — expected off real
hardware.

## Undo everything

```bash
./scripts/restore.sh --list     # see timestamped backups
./scripts/restore.sh            # restore the most recent
./scripts/restore.sh /path/to/backups/<timestamp>
```

To undo the whole deployment (generated config only — ROMs and media are kept):

```bash
./scripts/uninstall.sh --config <your-config> --dry-run   # preview
./scripts/uninstall.sh --config <your-config>             # remove generated config
./scripts/uninstall.sh --config <your-config> --remove-flatpaks   # also remove emulators+Pegasus
```

To remove a single installed emulator manually:

```bash
flatpak uninstall --user <app-id>
```

To update the managed Flatpaks:

```bash
./scripts/update.sh --config <your-config>
```

## Permissions GUI

Prefer a GUI for Flatpak permissions? Install Flatseal:

```bash
flatpak install --user flathub com.github.tchx84.Flatseal
```

and grant the emulator (and Pegasus) access to your ROM folder there.
