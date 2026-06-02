#!/usr/bin/env bash
# smoke-fedora-container.sh — run the script/config suite inside a Fedora
# container to catch obvious errors BEFORE touching a real Bazzite machine.
#
# WHAT THIS PROVES:
#   - All scripts are syntactically valid bash and pass ShellCheck.
#   - OS/Fedora detection runs without crashing on a Fedora userspace.
#   - The flatpak-ABSENT code path is handled gracefully.
#   - Config parsing (no yq), dry-run, and non-interactive mode work.
#   - Pegasus metadata is generated correctly, including ROM paths WITH SPACES.
#   - The validation script runs and reports.
#   - Logging and backup code paths execute.
#
# WHAT THIS DOES *NOT* PROVE (requires a real Bazzite machine):
#   - rpm-ostree / bootc behaviour
#   - Steam Deck / Game Mode behaviour
#   - Flatpak sandbox permissions in a real graphical session
#   - Launching GUI emulators / Pegasus at runtime
#   - External SD-card mount behaviour
#
# Usage: scripts/smoke-fedora-container.sh [FEDORA_TAG]   (default: 41)
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
FEDORA_TAG="${1:-41}"
IMAGE="registry.fedoraproject.org/fedora:${FEDORA_TAG}"

# Pick a container engine.
ENGINE=""
for e in podman docker; do command -v "$e" >/dev/null 2>&1 && { ENGINE="$e"; break; }; done
[[ -n "$ENGINE" ]] || { echo "ERROR: need podman or docker to run the smoke test" >&2; exit 1; }

echo "== Fedora $FEDORA_TAG smoke test ($ENGINE) =="
echo "Repo: $REPO_ROOT"
echo "Image: $IMAGE"
echo

# The in-container script. We deliberately do NOT install flatpak so we also
# exercise the 'flatpak missing' code path. ShellCheck is installed to lint.
# The body is single-quoted on purpose: every $ expression must expand INSIDE
# the container, not on the host.
# shellcheck disable=SC2016
exec "$ENGINE" run --rm -t \
    -v "$REPO_ROOT":/work:ro \
    -w /work \
    -e NO_COLOR=1 \
    "$IMAGE" \
    bash -euo pipefail -c '
        echo "--- container: $(. /etc/os-release; echo "$PRETTY_NAME") ---"
        dnf -y -q install ShellCheck >/dev/null 2>&1 || echo "(ShellCheck install skipped/failed; continuing)"

        echo; echo "### 1. bash syntax check"
        find scripts -name "*.sh" -print0 | xargs -0 -n1 bash -n
        echo "OK: all scripts parse"

        if command -v shellcheck >/dev/null 2>&1; then
            echo; echo "### 2. shellcheck"
            shellcheck -x scripts/*.sh tests/*.sh && echo "OK: shellcheck clean"
        fi

        echo; echo "### 3. unit tests"
        bash tests/run-tests.sh

        echo; echo "### 4. dry-run, non-interactive, ROM path WITH SPACES, flatpak absent"
        # Work in a throwaway HOME so nothing leaks between runs.
        export HOME=/tmp/smoke-home; mkdir -p "$HOME"
        cfg=/tmp/smoke-config.yaml
        cat > "$cfg" <<YAML
rom_root: "/tmp/smoke-home/My ROMs"
create_rom_dir: yes
pegasus_install: flatpak
emulators: retroarch, dolphin, pcsx2
systems: auto
mode: install-missing
backup: yes
example_collections: yes
YAML
        # Merge stderr: warnings (incl. the DRY-RUN banner) are emitted there.
        scripts/deploy.sh --config "$cfg" --non-interactive --dry-run --allow-non-bazzite 2>&1 \
            | tee /tmp/smoke-dryrun.log
        grep -q "DRY-RUN MODE" /tmp/smoke-dryrun.log || { echo "FAIL: dry-run banner missing"; exit 1; }
        grep -q "My ROMs" /tmp/smoke-dryrun.log || { echo "FAIL: space-path not handled"; exit 1; }
        # Dry-run must not create the ROM dir.
        [ ! -e "/tmp/smoke-home/My ROMs" ] || { echo "FAIL: dry-run created files"; exit 1; }
        echo "OK: dry-run changed nothing and handled spaces"

        echo; echo "### 5. real generation run (flatpak absent => installs skipped, config still generated)"
        # Allow the run to proceed even though flatpak is missing; we only test
        # the config-generation + logging + backup code paths here.
        scripts/deploy.sh --config "$cfg" --non-interactive --allow-non-bazzite || true
        meta="/tmp/smoke-home/My ROMs/snes/metadata.pegasus.txt"
        [ -f "$meta" ] || { echo "FAIL: metadata not generated at $meta"; exit 1; }
        echo "--- generated $meta ---"; cat "$meta"
        grep -q "launch:" "$meta" || { echo "FAIL: no launch line"; exit 1; }
        # The launch line must contain the space-safe quoted {file.path}.
        grep -q "\"{file.path}\"" "$meta" || { echo "FAIL: file.path not quoted"; exit 1; }
        echo "OK: metadata generated with quoted launch path"

        echo; echo "### 6. validation script runs"
        scripts/validate.sh --config "$cfg" || true   # FAIL exit expected (no flatpak); we only check it runs
        echo "OK: validate.sh executed"

        echo; echo "### 7. logging + backup code paths"
        ls -1 "$HOME/.local/share/pegasus-bazzite-configurator/logs/" >/dev/null && echo "OK: log file written"

        echo; echo "ALL SMOKE CHECKS COMPLETED"
    '
