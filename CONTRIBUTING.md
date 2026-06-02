# Contributing

Thanks for helping improve **pegasus-bazzite-configurator**. This is a Bash
project (one small Python helper) that configures Pegasus Frontend + emulators
on Bazzite (Fedora Atomic). Keep changes safe, reversible, and user-space — the
target is an immutable OS.

## Repository layout

```
scripts/            entrypoints (deploy/validate/restore/uninstall/update/…)
scripts/lib/        sourced modules: common, detect, prereq, config,
                    emulators, pegasus, backup, steam_shortcuts.py
config/             example-config.yaml + systems/*.conf (data-driven catalog)
docs/               ARCHITECTURE, BAZZITE_NOTES, PEGASUS_CONFIG,
                    EMULATOR_SUPPORT, TROUBLESHOOTING, TESTING
tests/              run-tests.sh (dependency-free unit tests)
```

Read [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) first — it explains the
dry-run executor, config precedence, the backup model, and the two correctness
details (Flatpak ROM access + cross-sandbox launching) that drive the design.

## Local development gate

Run before every commit (no Bazzite needed):

```bash
make check          # bash -n + ShellCheck (entrypoints + lib/) + unit tests
make smoke-fedora   # full suite in a Fedora 44 container (needs podman/docker)
```

- ShellCheck must be clean. The `.shellcheckrc` enables `external-sources`
  (so sources into `lib/` are followed) and disables SC2034 (cross-module state
  globals are a false positive in a sourced-library codebase).
- Add/adjust unit tests in `tests/run-tests.sh` for any pure function you touch
  (parsing, quoting, path/launch-line generation, catalog helpers). Assertions
  must run **without subshells** so the suite's exit code stays meaningful.
- Every state-changing action must flow through `run_cmd` / `write_file` in
  `common.sh` so `--dry-run` stays correct by construction.

## How to add a system or emulator

- **New system:** drop a `config/systems/<short>.conf` (see
  [`docs/PEGASUS_CONFIG.md`](docs/PEGASUS_CONFIG.md#adding-a-new-system)).
- **New emulator:** add a catalog entry in `scripts/lib/emulators.sh` and point a
  system at it (see
  [`docs/EMULATOR_SUPPORT.md`](docs/EMULATOR_SUPPORT.md#adding-another-emulator)).
- Never bundle BIOS, ROMs, firmware, or keys. Document where the user supplies
  them and add a BIOS path to `EMU_BIOS_DIR` if the emulator needs one.

## Branch / commit / PR conventions

- Branch per issue: `feature/<n>-slug`, `fix/<n>-slug`, `docs/<n>-slug`,
  `infra/<n>-slug`.
- Conventional-ish commit subjects: `feat:`, `fix:`, `docs:`, `infra:`, `test:`.
- One issue per PR; PR body says `Closes #<n>`, lists changes, and how it was
  tested. Use the PR template.
- CI (ShellCheck + lib lint + unit tests + Fedora 42/43/44 smoke + Python
  byte-compile) must be green before merge.

## The hardware boundary

A Fedora container catches script/config errors but **cannot** prove runtime
behaviour. Anything touching real installs, Game Mode, the live Flatpak sandbox,
SD-card mounts, or emulator runtime must be validated on a real Bazzite machine —
see [`docs/TESTING.md`](docs/TESTING.md). Don't claim those work from a green
container run; say what was and wasn't verified.

## Filing issues

Use the templates under `.github/ISSUE_TEMPLATE/`. Good issues are actionable
with clear acceptance criteria. For bugs, include `os-release`, device, and the
log under `~/.local/share/pegasus-bazzite-configurator/logs/`.
