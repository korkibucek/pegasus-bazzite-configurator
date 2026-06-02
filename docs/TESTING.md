# Testing

## Layers

| Layer | Command | Runs where | Proves |
|---|---|---|---|
| Syntax | `make syntax` | dev host | every script parses (`bash -n`) |
| Lint | `make lint` | dev host | ShellCheck-clean (follows sources into `lib/`) |
| Unit | `make test` | dev host / container | pure functions: detection, YAML parse, quoting, launch-line, validation, backup-path |
| Smoke | `make smoke-fedora` | Fedora container (podman/docker) | end-to-end dry-run + generation + validation, flatpak-absent path, ROM paths with spaces, logging/backup |
| Real | manual | a real Bazzite machine | actual installs, launching, Game Mode, sandbox at runtime |

`make check` runs syntax + lint + unit (fast local gate).

## Unit tests

`tests/run-tests.sh` sources the libraries and asserts on pure functions using
fixtures (e.g. synthetic `os-release` files for Bazzite/Fedora/Ubuntu). It runs
in seconds and needs nothing installed. It uses no subshells around assertions,
so the process exit code reflects any failure (CI relies on this).

## Fedora container smoke test

```bash
make smoke-fedora                         # default: Fedora 44 (Bazzite 44's base)
./scripts/smoke-fedora-container.sh 43    # pick a Fedora tag
# Run against a Bazzite image you trust (script-level checks only; still cannot
# exercise rpm-ostree/Game-Mode/sandbox/runtime):
PBC_SMOKE_IMAGE=ghcr.io/ublue-os/bazzite ./scripts/smoke-fedora-container.sh
```

> There is no official Bazzite image on Docker Hub (only unofficial mirrors),
> so the harness defaults to Fedora 44 — the base Bazzite 44 is built on — and
> lets you point `PBC_SMOKE_IMAGE` at any image you trust.

What it does, step by step:

1. `bash -n` on all scripts.
2. ShellCheck (installed in the container).
3. Unit tests.
4. **Dry-run**, non-interactive, with a `rom_root` containing a space, and
   **flatpak deliberately absent** — asserts nothing was created and the spaced
   path is handled.
5. A **real generation run** (flatpak absent ⇒ installs skipped) — asserts the
   `metadata.pegasus.txt` is generated with a correctly quoted `{file.path}`.
6. Runs `validate.sh` (expected to report failures for the absent emulators —
   we only assert it runs).
7. Confirms a log file was written.

### What the container proves

Script/config correctness: syntax, lint, detection logic on a Fedora userspace,
dependency detection, config parsing (no `yq`), dry-run safety, non-interactive
mode, metadata generation, **path quoting including spaces**, logging, and backup
code paths.

### What the container does NOT prove

- `rpm-ostree` / `bootc` behaviour
- Steam Deck / Game Mode (gamescope) behaviour
- Flatpak sandbox permissions in a real graphical session
- Launching GUI emulators / Pegasus at runtime
- External SD-card mount behaviour
- Real emulator runtime (BIOS, cores, performance)

These require a real Bazzite machine. Treat a green smoke test as "no obvious
breakage", not "verified on target".

## Manual verification checklist (real Bazzite)

1. `./scripts/deploy.sh --dry-run` — review intended actions.
2. `./scripts/deploy.sh` — interactive install.
3. `./scripts/validate.sh` — expect PASS.
4. Place a legally obtained test ROM in a system folder.
5. Launch Pegasus (Desktop Mode, then added to Steam for Game Mode) and confirm
   the collection appears and the game launches.
6. If on a handheld with ROMs on SD: confirm the emulator can read the card
   (sandbox override) and re-test launching.

## CI

`.github/workflows/ci.yml` runs, on push/PR (free GitHub-hosted runners only):

- **shellcheck** — lints the entrypoints (following sources into `lib/`) *and*
  the `lib/*.sh` modules directly.
- **unit-tests** — `tests/run-tests.sh`.
- **fedora-smoke** — the smoke suite across a Fedora matrix (42/43/44);
  non-44 tags are `continue-on-error` so the matrix never blocks on a tag that
  is not currently published.
