# Scraping artwork & metadata

`deploy.sh` creates your Pegasus collections and launch commands, but it does
**not** fetch box art, screenshots, or descriptions — that's what
`scripts/autoscraper.sh` is for. It runs **Skyscraper** to scrape
[ScreenScraper.fr](https://www.screenscraper.fr/) and writes richer
`metadata.pegasus.txt` files plus media into each system folder.

## Why a container?

Bazzite is immutable/atomic — you can't install Skyscraper onto the host, the
upstream project is archived, and the prebuilt images currently 403. So the
script compiles the maintained [`gemba/skyscraper`](https://github.com/gemba/skyscraper)
fork inside a throwaway **Podman** container (Ubuntu 22.04 base), built once and
cached locally as `localhost/bazzite-skyscraper`. Nothing is layered onto the
host. Bind mounts use SELinux's `:Z` label so the container can read/write your
ROMs and cache.

## Usage

```bash
# Interactive (prompts for ROM path, system, ScreenScraper login):
./scripts/autoscraper.sh

# Reuse your deploy config's ROM root, scrape one system:
./scripts/autoscraper.sh --config config/local-mydeck.yaml --system snes

# Scrape everything, non-interactive, with a ScreenScraper account:
./scripts/autoscraper.sh --roms ~/ROMs --system all --user YOURNAME

# Preview the exact podman commands without building/running anything:
./scripts/autoscraper.sh --roms ~/ROMs --system all --dry-run
```

Key flags: `--config FILE`, `--roms DIR`, `--system NAME|all`, `--user NAME`,
`--rebuild` (rebuild the container image), `-G/--generate-only` (re-emit
metadata from the existing cache without re-scraping), `--dry-run`, `-y/--yes`,
`-h/--help`. Run `./scripts/autoscraper.sh --help` for all of them.

### Paths & the overwrite prompt (important)

The ROM directory is bind-mounted into the container **at its real host path**,
so the `file:` and `assets.*` paths Skyscraper writes into `metadata.pegasus.txt`
are valid for Pegasus on the host (not container-only `/roms/...` paths). The
scraper also passes Skyscraper `--flags unattend` so it **overwrites the
`metadata.pegasus.txt` that `deploy.sh` created** without an interactive prompt —
otherwise Skyscraper asks "overwrite? (y/N)" and, on anything but `y`, writes
nothing (so scraping appears to do nothing). Your `collection`/`launch`/
`extensions` header is preserved across the overwrite.

If you scraped before this behaviour and Pegasus shows no art, just re-run with
`--generate-only` (no re-download needed) to rebuild the metadata from cache:

```bash
./scripts/autoscraper.sh --roms ~/ROMs --system all --generate-only -y
```

## How it works

1. **First run** builds `localhost/bazzite-skyscraper` (a few minutes; cached
   afterwards — use `--rebuild` to refresh).
2. For each system folder it runs Skyscraper **twice**:
   - **gather** — `-s screenscraper` downloads art/metadata into the cache
     (`~/.skyscraper`, mounted into the container);
   - **generate** — `-f pegasus` writes `metadata.pegasus.txt` + media into the
     system folder.
3. Launch Pegasus to see the updated library.

## ScreenScraper account

ScreenScraper heavily rate-limits anonymous scraping. A free account
(passed via `--user`, with the password prompted) gives you usable throughput.
Credentials are only handed to the Skyscraper container for that run; nothing is
stored by this tool.

## Interaction with `deploy.sh`

- Run `deploy.sh` first to create the collections, then `autoscraper.sh` to
  enrich them.
- The scraper overwrites `metadata.pegasus.txt` in each scraped system with
  Skyscraper's richer output. If you then re-run `deploy.sh`, use the default
  `install-missing` mode (not `--force`) so it won't clobber the scraped files.
- ROM folder names should match ScreenScraper's platform names (the same
  shortnames this tool uses — `snes`, `psx`, `n64`, …). For ES-DE/EmuDeck
  layouts the names line up in most cases.

## Requirements & limitations

- **Podman** (preinstalled on Bazzite). Needs a terminal (the container runs
  interactively to show progress).
- This is a thin, isolated wrapper around Skyscraper; deep Skyscraper
  configuration (artwork layouts, regions, etc.) lives in
  `~/.skyscraper/config.ini` and is out of scope here.
- No runtime scraping happens in CI or the Fedora smoke test — only `--help`
  and `--dry-run` (command preview) are exercised there; real scraping is
  validated on Bazzite.
