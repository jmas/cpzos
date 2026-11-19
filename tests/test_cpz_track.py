"""Host-side tests for the headset track-button helper."""

from __future__ import annotations

import os
import subprocess
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
TRACK = FILES / "cpz-track"
MEDIA_KEYS = FILES / "cpz-media-keys"


class TrackButtonTest(unittest.TestCase):
    def run_track(
        self, action: str | None, cmus_running: bool = True, position: int = 0
    ):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        calls = root / "calls.log"

        pgrep = bin_dir / "pgrep"
        pgrep.write_text(
            f"#!/bin/sh\nexit {0 if cmus_running else 1}\n", encoding="utf-8"
        )
        remote = bin_dir / "cmus-remote"
        remote.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "-Q" ]; then\n'
            '  printf "status playing\\nposition %s\\n" "$CPZ_TEST_POSITION"\n'
            "  exit 0\n"
            "fi\n"
            'printf "%s\\n" "$*" >>"$CPZ_TEST_LOG"\n'
            "exit 0\n",
            encoding="utf-8",
        )
        for shim in (pgrep, remote):
            shim.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
        env["CPZ_TEST_LOG"] = str(calls)
        env["CPZ_TEST_POSITION"] = str(position)
        args = [str(TRACK)] if action is None else [str(TRACK), action]
        result = subprocess.run(
            args, env=env, text=True, capture_output=True, timeout=10
        )
        output = calls.read_text(encoding="utf-8") if calls.exists() else ""
        return result, output

    def test_next_skips_forward(self):
        result, calls = self.run_track("next")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.strip(), "-C player-next")

    def test_prev_goes_back(self):
        result, calls = self.run_track("prev", position=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.strip(), "-C player-prev")

    def test_prev_from_mid_track_steps_back_instead_of_restarting(self):
        # cmus restarts a track that has been playing for a few seconds. The
        # button sends a restart and then the actual step back.
        result, calls = self.run_track("prev", position=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls.splitlines(), ["-C player-prev", "-C player-prev"]
        )

    def test_toggle_pauses_and_resumes(self):
        result, calls = self.run_track("toggle")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.strip(), "-C player-pause")

    def test_press_without_a_player_is_ignored(self):
        result, calls = self.run_track("next", cmus_running=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, "")

    def test_bad_action_is_rejected(self):
        result, _ = self.run_track("stop")
        self.assertEqual(result.returncode, 2)

    def test_media_keys_map_to_track_actions(self):
        # The centre button toggles play/pause; the volume rocker changes the
        # volume on a tap and skips tracks when held.
        text = MEDIA_KEYS.read_text(encoding="utf-8")
        self.assertIn('164: [TRACK, "toggle"]', text)
        self.assertIn('163: [TRACK, "next"]', text)
        self.assertIn('165: [TRACK, "prev"]', text)
        self.assertIn('115: [TRACK, "next"]', text)
        self.assertIn('114: [TRACK, "prev"]', text)
        self.assertIn('115: [VOLUME, "up"]', text)

    def test_a_held_volume_key_skips_only_after_the_threshold(self):
        loader = SourceFileLoader("cpz_media_keys", str(MEDIA_KEYS))
        spec = spec_from_loader("cpz_media_keys", loader)
        assert spec is not None
        module = module_from_spec(spec)
        loader.exec_module(module)

        calls: list[list[str]] = []
        module.run = calls.append
        held = {115: (100.0, False)}

        # Still inside the threshold: nothing happens and the loop waits.
        wait = module.fire_long_presses(held, 100.3)
        self.assertEqual(calls, [])
        self.assertAlmostEqual(wait, 0.3, places=3)

        # Past the threshold the track changes once, then the key is spent.
        module.fire_long_presses(held, 100.7)
        self.assertEqual(calls, [[module.TRACK, "next"]])
        self.assertTrue(held[115][1])
        module.fire_long_presses(held, 101.0)
        self.assertEqual(calls, [[module.TRACK, "next"]])


if __name__ == "__main__":
    unittest.main()
