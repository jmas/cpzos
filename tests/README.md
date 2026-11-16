# Tests

Fast checks that need no root, no Docker and no Raspberry Pi hardware.

```sh
./tests/run.sh    # unit tests for cpz-settings and cpz-hdmi-console
./tests/lint.sh   # shellcheck + ruff + mypy
```

`tests/run.sh` needs only `python3` and `sh`. `tests/lint.sh` needs the dev
tools:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install ruff==0.17.5 mypy==1.19.1 shellcheck-py==0.11.0.1
```

The CI workflow pins the same versions so a new linter release cannot fail a
PR without a matching change here.

CI runs `tools/verify-stage.sh`, `tests/run.sh` and `tests/lint.sh` on every
pull request (`.github/workflows/ci.yml`).

## What is covered

- `test_cpz_settings.py` loads the extension-less `cpz-settings` file as a
  module and checks settings precedence, defaults/clamping, save/load
  round-trip, layout normalization, the date/time editor helpers and the
  internal submenu graph (`--check-pages`).
- `test-hdmi-console.sh` sources `cpz-hdmi-console` in library mode
  (`CPZ_HDMI_CONSOLE_LIB=1`) and checks the output policy (panel vs HDMI) and
  the panel/HDMI font selection for common modes without touching a console.

The tests are intentionally host-only. Hardware behaviour (DRM modesets,
hotplug timing, backlight) still needs the debug image on a device; see
`docs/CPZ-FBCON.md`.
