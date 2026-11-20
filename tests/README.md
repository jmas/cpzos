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
  internal submenu graph (`--check-pages`), menu label widths, long-list
  filtering and the CPZ Hub catalog loading, scoped manager state and install/remove policy.
- `test_cpz_output.py` runs a copy of `cpz-cage-output` against a fake
  sysfs/settings tree and checks that `display=panel` is honoured both by the
  systemd unit, the generated cage environment and the panel backlight,
  including while the screensaver lock owns the panel.
- `test_cpz_idle.py` checks the screensaver timeout parser and the idle
  threshold used by `cpz-idle`.
- `test_cpz_lock.py` checks the Tab-then-Enter unlock sequence, the localized
  lock prompt and the backlight marker hand-off to `cpz-brightness`.
- `test_cpz_i18n.py` checks the English/Ukrainian/German catalogs, fallback,
  placeholders, language normalization and the Settings Language selector.
- `test_cpz_pointer.py` runs `cpz-pointer` against a fake sysfs input tree and
  checks that phantom HDMI/keyboard pointer bits are stripped, that a real USB
  mouse keeps its cursor only when Mouse Support is on, that touchscreens stay
  usable, and that a settings change reopens pointer devices once without
  restarting cage. It also checks that a keymap reload reopens only keyboards.
- `test_cpz_cage_session.py` runs the session supervisor against a fake foot
  and checks that a reload replaces only the visible terminal while the anchor
  keeps the session alive, that the ready marker is published, and that
  shutdown removes the pid files.
- `test_cpz_run.py` checks that `cpz-run` applies the Wayland/X11 environment
  published by the foot client and still works without it.
- `test_cpz_foot.py` renders the foot configuration against a fake theme and
  checks the Terminus pixel size, background/foreground and 16-colour palette.
- `test_cpz_search.py` checks the `cpz-search` providers (the short action
  home list, commands, actions, Settings, power actions, files, calculator,
  Hub apps and tmux buffers), item format, file roots/pruning, safe
  calculator, dispatch to the Settings tab and the `cpz-settings` entry points
  used by the CPZ Search popup (`--page`, `--tool`, `--list-pages`,
  `--list-tools`, `--install-tool`, request queue).
- `test_cpz_keys.py` checks the shortcut registry rules (one Alt key plus one
  plain key, unique defaults, no punctuation/Sym/Fn chords), override
  precedence and conflicts, generated tmux bindings, and that tmux/help/search/
  Settings consume the same registry instead of hard-coded keys.
- `test_cpz_volume.py` runs `cpz-volume` against a fake `wpctl` and checks the
  5% step, 0-100 clamping, mute toggling, missing-audio handling and the
  Sound actions in the shortcut registry.
- `test_cpz_automount.py` sources `cpz-automount` and checks label sanitising
  (no path traversal), per-filesystem mount options, mount-point selection,
  device-path validation and the disk tab hooks around mount/unmount.
- `test_cpz_tab_mount.py` runs `cpz-tab-mount` against a fake tmux and checks
  that a disk tab opens in the mount point and only tabs still on the disk are
  closed before unmounting.
- `test_cpz_battery.py` runs `cpz-battery` against a fake power_supply tree and
  checks the warn/shutdown/boot thresholds, the charging escape, the voltage
  floor and the boot-time poweroff hand-off.
- `test_cpz_layout_map.py` checks the language-aware CPZ Sym overlay: letter
  detection (Unicode/ASCII/function keysyms), the unchanged Latin table, the
  removed letter keycodes and the relocated ASCII punctuation on Shift+Sym.
- `test_state_contract.py` scans runtime shell helpers for writes to `/etc`
  and `/var`, and keeps the known-deviation allowlist current. The normative
  rules are in `docs/STATE.md`.
- `test_update_os_list.py` checks the os-list naming rules used by the release
  workflow: SemVer tags (`v0.1.0`), prerelease suffixes and legacy timestamp
  tags.
- `test_build_fast.py` runs `tools/build-fast.sh` against a fake Docker binary
  and checks the generated `STAGE_LIST`, `PREV_ROOTFS_DIR` and compression
  config for stage2/stage3.

The tests are intentionally host-only. Hardware behaviour (DRM modesets,
cage hotplug, panel rendering, backlight) still needs the debug image on a
device; see `docs/CPZ-CAGE.md`.

UI changes also follow [`docs/CPZ-UI.md`](../docs/CPZ-UI.md): the purpose test,
label width, footer keys, long-list filtering and the exception process.
