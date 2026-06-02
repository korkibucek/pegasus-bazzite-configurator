# Bazzite / Fedora Atomic notes

Bazzite is **not** Ubuntu/Debian and not a normal mutable Fedora. It is a
[Universal Blue](https://universal-blue.org/) image built on **Fedora Atomic**
(`rpm-ostree` / `bootc`). This document records the platform facts that shaped
this tool's design and the things that still need a real machine to verify.

## Immutable / image-based system

- The base OS is a versioned, largely read-only image. You don't `dnf install`
  into `/usr` casually.
- Installing software the "Fedora way" means **`rpm-ostree install`** (layering),
  which **requires a reboot**, slows future updates, and can conflict with image
  updates. We therefore **avoid layering by default** and prefer Flatpak.
- This tool requires **no root** and makes **no system mutation** in its default
  path — everything is `flatpak --user` and files under `$HOME`.

## Detection (how we identify the platform)

We read evidence rather than trusting a single field (`scripts/lib/detect.sh`):

- `/etc/os-release`: `ID`, `ID_LIKE`, `VARIANT_ID`, `IMAGE_ID`, `PRETTY_NAME`.
  Bazzite may identify itself in `ID`, `IMAGE_ID`, or `PRETTY_NAME` depending on
  the image generation, so we match the `bazzite` substring across all of them.
- `/run/ostree-booted` and `rpm-ostree status` → atomic/ostree system.
- DMI (`/sys/class/dmi/id/sys_vendor`, `product_name`): `Valve` / `Jupiter`
  (Steam Deck LCD) / `Galileo` (OLED), plus ROG Ally, Legion Go, AYANEO → treated
  as **handheld** (defaults lean toward Game Mode + controller-friendly).

If the system is Fedora-like but not Bazzite, the tool warns and asks (or
requires `--allow-non-bazzite`). On a non-Fedora host it refuses unless
overridden.

## Flatpak is the install path

GUI emulators and Pegasus are installed from **Flathub at `--user` scope**:

```bash
flatpak install --user flathub <app-id>
```

Bazzite ships Flatpak and usually the Flathub remote; if the remote is missing we
add it at user scope. User-scope installs are per-user, need no root, and are
trivially reversible (`flatpak uninstall --user <app-id>`).

## The Flatpak sandbox vs your ROMs (the big gotcha)

A Flatpak emulator runs sandboxed and **cannot read your ROM directory** unless
granted. Symptom: Pegasus launches the emulator but the game is "not found" or
the file picker can't see it.

We fix this for every selected emulator:

```bash
flatpak override --user <emulator-app-id> --filesystem="/path/to/ROMs"
```

- Inspect current grants: `flatpak info --show-permissions <app-id>` and
  `flatpak override --user --show <app-id>`.
- `Flatseal` (`com.github.tchx84.Flatseal`) is the GUI equivalent if you prefer
  to review/adjust permissions visually.

### SD cards and external drives

On a Steam Deck the SD card mounts under `/run/media/deck/<LABEL>` (path varies).
If your ROMs live there, set `rom_root` accordingly **and** list the mount in
`extra_rom_paths` so the override covers it. Note that mount points can change
between sessions; a stable approach is to keep `rom_root` on internal storage or
to re-run the tool if the mount path changes.

## Cross-sandbox launching (Pegasus → emulator)

When Pegasus itself is a Flatpak, it cannot directly run another Flatpak from
inside its sandbox. The tool:

- prefixes launch commands with `flatpak-spawn --host`, and
- grants Pegasus `flatpak override --user org.pegasus_frontend.Pegasus --talk-name=org.freedesktop.Flatpak`.

If you install Pegasus as a native binary/AppImage instead, no prefix is needed
(launch lines are plain `flatpak run …`).

## Reusing an existing EmuDeck / ES-DE library

Many Bazzite users already run EmuDeck, which stores ROMs under `~/Emulation/roms`
(or the same path on an SD card). The tool detects this and, rather than creating
a parallel `~/ROMs` tree, can adopt it as `rom_root`:

- **Interactive**: the detected library becomes the default in the ROM-root
  prompt (confirm or change it).
- **Non-interactive**: set `reuse_existing_library: yes` to opt in (default
  `auto` does not adopt unattended, to avoid surprises).

Folder names are reconciled with ES-DE where they differ — e.g. ES-DE uses `gc`
for GameCube, so metadata is written into the existing `gc` folder instead of a
new `gamecube` one (see the alias map in `scripts/lib/pegasus.sh`). **ROM files
are never moved or deleted** — only `metadata.pegasus.txt` is written and
directories registered with Pegasus. If a system has no matching folder, a fresh
one is created (an empty collection) and reported in the log.

## Game Mode vs Desktop Mode

- **Desktop Mode**: launch Pegasus like any app (`flatpak run
  org.pegasus_frontend.Pegasus`).
- **Game Mode** (Steam Deck UI / gamescope session): add Pegasus to Steam as a
  non-Steam game and launch it from there, so it runs inside the gamescope
  session with controller input. The generated launch commands work in both; the
  `flatpak-spawn --host` prefix is what lets a Flatpak Pegasus start emulators
  from within Game Mode.

  Automate the "add to Steam" step (with Steam closed):

  ```bash
  ./scripts/add-to-steam.sh --dry-run   # preview
  ./scripts/add-to-steam.sh             # add the shortcut
  ```

  This edits Steam's binary `shortcuts.vdf` safely: it refuses to run while
  Steam is open, backs the file up first, and appends without disturbing your
  other non-Steam shortcuts. Restart Steam afterwards; the shortcut appears in
  your library.

## What a Fedora container proves — and what it cannot

The smoke test (`make smoke-fedora`) runs the suite in a Fedora container and
proves: script syntax, ShellCheck cleanliness, detection logic, config parsing,
dry-run, non-interactive mode, metadata generation, path quoting (incl. spaces),
validation flow, logging, and backup code paths.

It **cannot** reproduce: `rpm-ostree`/`bootc` behaviour, Game Mode / gamescope,
Flatpak sandbox permissions in a real graphical session, launching GUI apps,
external SD-card mount behaviour, or real emulator runtime. Those require a real
Bazzite machine — see [TESTING.md](TESTING.md).
