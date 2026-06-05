# Roadmap & status

## Status — v1.0.0

Released and validated end-to-end on real Bazzite (Bazzite 44, desktop): platform
detection, Flatpak emulator installs with ROM-path sandbox permissions, Pegasus
install + config generation, RetroArch core download, Vita3K-via-AppImage,
artwork/metadata scraping (Skyscraper/Podman), and library cleanup all confirmed
working on hardware. CI runs ShellCheck, the unit suite, and a Fedora 42/43/44
smoke matrix on every change.

## Known limitations

- **Runtime depends on your files.** BIOS/firmware (PCSX2, RPCS3, DuckStation,
  some RetroArch cores) and ROMs are user-supplied; nothing copyrighted is ever
  installed. `validate.sh` flags missing BIOS/cores.
- **Multi-disc games** (e.g. FF7 Disc 1/2/3) list one entry per disc — Pegasus
  discovers files by the collection's `extensions:` glob, so per-disc grouping
  needs generated `.m3u` playlists (planned, below).
- **ScummVM / MAME** need per-game / per-romset setup beyond a generic launch line.
- **Vita3K** is experimental; PS Vita support is best-effort (installed titles,
  firmware required).
- **Container caveat.** The Fedora smoke test catches script/config errors but
  cannot prove rpm-ostree, Game Mode, the live Flatpak sandbox, or emulator
  runtime — those are validated on real Bazzite. See [TESTING.md](TESTING.md).

## Planned / candidate work

These are ideas, not commitments — file or upvote a GitHub issue to prioritise.

- **Multi-disc `.m3u` grouping** — generate an `.m3u` per multi-disc game and
  list only that, so a game shows once instead of once per disc.
- **More emulators/systems** as clean Flathub (or AppImage) options appear.
- **Optional artwork layout tuning** for Skyscraper (regions, aspect, video).
- **Per-system extension presets** surfaced in config for unusual ROM sets.
- **Switch emulation** remains intentionally out (no maintained,
  legitimately-distributable Flathub option); revisit only if that changes.

## How to propose changes

Open a GitHub issue with clear acceptance criteria (templates under
`.github/ISSUE_TEMPLATE/`), then a PR that `Closes #N`. See
[CONTRIBUTING.md](../CONTRIBUTING.md) and the green-CI gate (`make check`,
`make smoke-fedora`).
