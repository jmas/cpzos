"""Host-side tests for the CPZ volume shortcut helper.

``cpz-volume`` talks to PipeWire through ``wpctl``. The test replaces wpctl and
tmux with small stateful fakes so the 5% step, clamping and mute toggle can be
checked without audio hardware.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VOLUME = ROOT / "stage3" / "01-session" / "files" / "cpz-volume"

FAKE_WPCTL = """#!/bin/sh
state="$CPZ_TEST_VOLUME_STATE"
percent=$(cat "$state.percent")
muted=$(cat "$state.muted")
case "$1" in
  get-volume)
    awk -v p="$percent" -v m="$muted" 'BEGIN {
      printf "Volume: %.2f", p / 100
      if (m == 1) printf " [MUTED]"
      printf "\\n"
    }'
    ;;
  set-volume)
    awk -v v="$3" 'BEGIN { printf "%d\\n", (v * 100) + 0.5 }' \
      >"$state.percent"
    ;;
  set-mute)
    case "$3" in
      toggle) if [ "$muted" = 1 ]; then echo 0; else echo 1; fi >"$state.muted" ;;
      1) echo 1 >"$state.muted" ;;
      0) echo 0 >"$state.muted" ;;
    esac
    ;;
esac
"""

FAKE_TMUX = """#!/bin/sh
printf '%s\\n' "$*" >>"$CPZ_TEST_VOLUME_LOG"
exit 0
"""


class VolumeHelper(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.state = self.root / "state"
        self.state.with_suffix(".percent").write_text("40\n", encoding="utf-8")
        self.state.with_suffix(".muted").write_text("0\n", encoding="utf-8")
        self.log = self.root / "tmux.log"

        for name, text in (("wpctl", FAKE_WPCTL), ("tmux", FAKE_TMUX)):
            path = self.bin / name
            path.write_text(text, encoding="utf-8")
            path.chmod(0o755)

    def run_volume(self, action: str, path: str | None = None) -> subprocess.CompletedProcess:
        env = os.environ.copy()
        env["PATH"] = path or f"{self.bin}:/usr/bin:/bin"
        env["CPZ_TEST_VOLUME_STATE"] = str(self.state)
        env["CPZ_TEST_VOLUME_LOG"] = str(self.log)
        env["TMUX"] = "1"
        return subprocess.run(
            [str(VOLUME), action],
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=30,
        )

    def percent(self) -> int:
        return int(self.state.with_suffix(".percent").read_text(encoding="utf-8"))

    def muted(self) -> int:
        return int(self.state.with_suffix(".muted").read_text(encoding="utf-8"))

    def test_volume_up_and_down_use_five_percent_steps(self):
        self.assertEqual(self.run_volume("up").returncode, 0)
        self.assertEqual(self.percent(), 45)
        self.assertEqual(self.run_volume("down").returncode, 0)
        self.assertEqual(self.percent(), 40)
        self.assertIn("volume: 40%", self.log.read_text(encoding="utf-8"))

    def test_volume_is_clamped_to_zero_and_one_hundred(self):
        self.state.with_suffix(".percent").write_text("98\n", encoding="utf-8")
        self.assertEqual(self.run_volume("up").returncode, 0)
        self.assertEqual(self.percent(), 100)

        self.state.with_suffix(".percent").write_text("3\n", encoding="utf-8")
        self.assertEqual(self.run_volume("down").returncode, 0)
        self.assertEqual(self.percent(), 0)

    def test_mute_toggles_and_reports_state(self):
        self.assertEqual(self.run_volume("mute").returncode, 0)
        self.assertEqual(self.muted(), 1)
        self.assertIn("volume: muted", self.log.read_text(encoding="utf-8"))

        self.assertEqual(self.run_volume("mute").returncode, 0)
        self.assertEqual(self.muted(), 0)
        self.assertIn("volume: 40%", self.log.read_text(encoding="utf-8"))

    def test_bad_action_and_missing_wpctl(self):
        self.assertEqual(self.run_volume("sideways").returncode, 2)
        missing = self.root / "empty"
        missing.mkdir()
        result = self.run_volume("up", path=str(missing))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stderr, "")

    def test_registry_has_sound_actions(self):
        loader = SourceFileLoader(
            "cpz_keys_volume", str(VOLUME.parent / "cpz-keys")
        )
        spec = importlib.util.spec_from_loader(loader.name, loader)
        assert spec is not None
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        by_id = {action["id"]: action for action in module.ACTIONS}
        self.assertEqual(by_id["volume-up"]["default"], "M-u")
        self.assertEqual(by_id["volume-down"]["default"], "M-i")
        self.assertEqual(by_id["volume-mute"]["default"], "M-0")
        for action_id in ("volume-up", "volume-down", "volume-mute"):
            self.assertIn("cpz-volume", by_id[action_id]["command"])


if __name__ == "__main__":
    unittest.main()
