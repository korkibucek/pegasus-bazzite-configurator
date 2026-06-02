---
name: Bug report
about: Something didn't work on Bazzite (or in the tooling)
title: "[bug] "
labels: bug
---

## What happened

A clear description of the problem.

## Expected

What you expected instead.

## Environment

- Output of `cat /etc/os-release | grep -E 'PRETTY_NAME|IMAGE_ID|VARIANT_ID'`:
- Device (Steam Deck LCD/OLED, desktop, other handheld):
- Pegasus install (flatpak / appimage / native):
- Emulators selected:
- ROM location (internal / SD card path):

## To reproduce

Exact command(s) you ran, e.g.:

```bash
./scripts/deploy.sh --config config/local-mydeck.yaml --non-interactive
```

## Logs / validation

- Relevant lines from `~/.local/share/pegasus-bazzite-configurator/logs/…`
- Output of `./scripts/validate.sh`

## Notes

Did `./scripts/deploy.sh --dry-run` show the expected actions? Anything else.
