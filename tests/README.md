# Tests

Fast checks that need no root, no Docker and no Raspberry Pi hardware.

```sh
./tests/run.sh    # unit tests for cpz-settings and output policy
./tests/lint.sh   # shellcheck + ruff + mypy
```

`tests/run.sh` needs only `python3`. `tests/lint.sh` needs the dev tools:

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
  round-trip, layout normalization, the date/time editor helpers, the
  internal submenu graph (`--check-pages`) and the Terminal Trove catalog
  filters/apt parsing/manager state.
- `test_cpz_output.py` runs a copy of `cpz-kmscon-output` against a fake
  sysfs/settings tree and checks that `display=panel` is honoured both by the
  systemd unit and by `--auto`, and that kmscon disables `use-original-mode`.
- `test_cpz_search.py` checks the `cpz-search` providers (commands, actions,
  Settings, files, calculator, Terminal Trove and tmux buffers), item format,
  file roots/pruning, safe calculator and the `cpz-settings` entry points used
  by the omnisearch popup (`--page`, `--tool`, `--list-pages`, `--list-tools`).
- `test_cpz_automount.py` sources `cpz-automount` and checks label sanitising
  (no path traversal), per-filesystem mount options, mount-point selection and
  device-path validation.
- `test_cpz_layout_map.py` checks the language-aware CPZ Sym overlay: letter
  detection (Unicode/ASCII/function keysyms), the unchanged Latin table, the
  removed letter keycodes and the relocated ASCII punctuation on Shift+Sym.
- `test_update_os_list.py` checks the os-list naming rules used by the release
  workflow: SemVer tags (`v0.1.0`), prerelease suffixes and legacy timestamp
  tags.

The tests are intentionally host-only. Hardware behaviour (DRM modesets,
kmscon hotplug, backlight) still needs the debug image on a device; see
`docs/CPZ-KMSCON.md`.
