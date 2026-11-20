"""Host-side tests for the headset track-button helper."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
TRACK = FILES / "cpz-track"
MEDIA_KEYS = FILES / "cpz-media-keys"


class TrackButtonTest(unittest.TestCase):
    def run_track(
        self,
        action: str | None,
        cmus_running: bool = True,
        position: int = 0,
        at_end: bool = False,
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
        state = root / "now_playing"
        state.write_text("first", encoding="utf-8")
        remote.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "-Q" ]; then\n'
            '  printf "status playing\\nfile %s\\nposition %s\\n" \\\n'
            '    "$(cat "$CPZ_TEST_STATE")" "$CPZ_TEST_POSITION"\n'
            "  exit 0\n"
            "fi\n"
            'printf "%s\\n" "$*" >>"$CPZ_TEST_LOG"\n'
            'if [ "$2" = "player-next" ] && [ "${CPZ_TEST_AT_END:-0}" != 1 ]; then\n'
            '  echo second >"$CPZ_TEST_STATE"\n'
            "fi\n"
            "exit 0\n",
            encoding="utf-8",
        )
        for shim in (pgrep, remote):
            shim.chmod(0o755)

        env = os.environ.copy()
        env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
        env["CPZ_TEST_LOG"] = str(calls)
        env["CPZ_TEST_POSITION"] = str(position)
        env["CPZ_TEST_STATE"] = str(state)
        env["CPZ_TEST_AT_END"] = "1" if at_end else "0"
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

    def test_next_at_the_last_track_wraps_to_the_first(self):
        # cmus keeps the last track at the end of the playlist; the helper
        # activates the top of the playlist instead.
        result, calls = self.run_track("next", at_end=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            calls.splitlines(),
            ["-C player-next", "-C view 3", "-C win-top", "-C win-activate"],
        )

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

    def load_media_keys(self):
        loader = SourceFileLoader("cpz_media_keys", str(MEDIA_KEYS))
        spec = spec_from_loader("cpz_media_keys", loader)
        assert spec is not None
        module = module_from_spec(spec)
        loader.exec_module(module)
        calls: list[list[str]] = []
        module.run = calls.append
        return module, calls

    def test_media_keys_map_to_track_actions(self):
        # The centre button toggles play/pause, the rocker changes the volume
        # on every press and the side buttons step through the playlist.
        text = MEDIA_KEYS.read_text(encoding="utf-8")
        self.assertIn('163: [TRACK, "next"]', text)
        self.assertIn('165: [TRACK, "prev"]', text)
        self.assertIn('114: [VOLUME, "down"]', text)
        self.assertIn('115: [VOLUME, "up"]', text)
        self.assertIn('224: [BRIGHTNESS, "down"]', text)
        self.assertIn('225: [BRIGHTNESS, "up"]', text)
        self.assertIn("CENTRE = 164", text)
        self.assertIn("DOUBLE_PRESS", text)
        # The rocker no longer skips tracks when held.
        self.assertNotIn("LONG_PRESS", text)
        # The device's own keys must not gain the double press behaviour.
        self.assertIn('KEYBOARD = "tca8418c"', text)
        self.assertIn("if device == KEYBOARD:", text)

    def test_volume_press_acts_immediately(self):
        module, calls = self.load_media_keys()
        pending = {}
        module.press(115, "headset", pending, 100.0)
        module.press(114, module.KEYBOARD, pending, 100.0)
        self.assertEqual(calls, [[module.VOLUME, "up"], [module.VOLUME, "down"]])
        self.assertEqual(pending, {})

    def test_brightness_keys_step_the_backlight(self):
        module, calls = self.load_media_keys()
        pending = {}
        module.press(225, module.KEYBOARD, pending, 100.0)
        module.press(224, module.KEYBOARD, pending, 100.0)
        self.assertEqual(
            calls,
            [[module.BRIGHTNESS, "up"], [module.BRIGHTNESS, "down"]],
        )
        self.assertEqual(pending, {})

    def test_first_key_press_after_zero_restores_ten_percent(self):
        module, calls = self.load_media_keys()
        module.brightness_level = lambda: 0
        module.wake_panel(30)  # a letter key
        self.assertEqual(calls, [[module.BRIGHTNESS, "up"]])

    def test_key_press_above_zero_leaves_brightness_alone(self):
        module, calls = self.load_media_keys()
        module.brightness_level = lambda: 10
        module.wake_panel(30)
        self.assertEqual(calls, [])

    def test_brightness_keys_do_not_force_the_panel_on(self):
        # Fn+I at 0 must stay at 0; Fn+O already steps up through ACTIONS.
        module, calls = self.load_media_keys()
        module.brightness_level = lambda: 0
        module.wake_panel(224)
        module.wake_panel(225)
        self.assertEqual(calls, [])

    def test_lock_screen_owns_the_wake_while_locked(self):
        module, calls = self.load_media_keys()
        module.brightness_level = lambda: 0
        with mock.patch.object(module.os.path, "exists", return_value=True):
            module.wake_panel(30)
        self.assertEqual(calls, [])

    def test_brightness_level_reads_the_last_user_value(self):
        module, _ = self.load_media_keys()
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "config"
            directory = config / "cpz"
            directory.mkdir(parents=True)
            (directory / "settings.conf").write_text(
                "brightness=40\nbrightness=0\n", encoding="utf-8"
            )
            with mock.patch.dict(
                os.environ, {"XDG_CONFIG_HOME": str(config)}, clear=False
            ):
                self.assertEqual(module.brightness_level(), 0)

    def test_single_centre_press_toggles_after_the_window(self):
        module, calls = self.load_media_keys()
        pending = {}
        module.press(module.CENTRE, "headset", pending, 100.0)
        self.assertEqual(calls, [])
        wait = module.fire_pending(pending, 100.0 + module.DOUBLE_PRESS / 2)
        self.assertEqual(calls, [])
        self.assertAlmostEqual(wait, module.DOUBLE_PRESS / 2, places=3)
        module.fire_pending(pending, 100.0 + module.DOUBLE_PRESS)
        self.assertEqual(calls, [[module.TRACK, "toggle"]])
        self.assertEqual(pending, {})

    def test_double_centre_press_skips_forward_instead_of_pausing(self):
        module, calls = self.load_media_keys()
        pending = {}
        module.press(module.CENTRE, "headset", pending, 100.0)
        module.press(module.CENTRE, "headset", pending, 100.2)
        self.assertEqual(calls, [[module.TRACK, "next"]])
        module.fire_pending(pending, 101.0)
        self.assertEqual(calls, [[module.TRACK, "next"]])
        self.assertEqual(pending, {})

    def test_keyboard_centre_press_stays_plain_play_pause(self):
        module, calls = self.load_media_keys()
        pending = {}
        module.press(module.CENTRE, module.KEYBOARD, pending, 100.0)
        module.press(module.CENTRE, module.KEYBOARD, pending, 100.1)
        self.assertEqual(
            calls, [[module.TRACK, "toggle"], [module.TRACK, "toggle"]]
        )
        self.assertEqual(pending, {})


if __name__ == "__main__":
    unittest.main()
