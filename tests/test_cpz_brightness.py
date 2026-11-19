"""Step tests for the cpz-brightness helper."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIGHTNESS = ROOT / "stage3" / "01-session" / "files" / "cpz-brightness"


class BrightnessStep(unittest.TestCase):
    def run_step(self, level: int, action: str) -> tuple[str, int]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config" / "cpz"
            config.mkdir(parents=True)
            settings = config / "settings.conf"
            settings.write_text(f"brightness={level}\n", encoding="utf-8")
            env = os.environ.copy()
            env["XDG_CONFIG_HOME"] = str(root / "config")
            env["HOME"] = str(root / "home")
            result = subprocess.run(
                ["sh", str(BRIGHTNESS), action],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            saved = settings.read_text(encoding="utf-8")
        self.assertEqual(result.returncode, 0, result.stderr)
        value = next(
            int(line.split("=", 1)[1])
            for line in saved.splitlines()
            if line.startswith("brightness=")
        )
        return saved, value

    def test_up_and_down_step_by_ten(self):
        _, up = self.run_step(50, "up")
        self.assertEqual(up, 60)
        _, down = self.run_step(50, "down")
        self.assertEqual(down, 40)

    def test_steps_clamp_to_the_settings_range(self):
        _, high = self.run_step(100, "up")
        self.assertEqual(high, 100)
        _, low = self.run_step(10, "down")
        self.assertEqual(low, 10)

    def test_unknown_action_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            env = os.environ.copy()
            env["XDG_CONFIG_HOME"] = str(Path(temporary) / "config")
            result = subprocess.run(
                ["sh", str(BRIGHTNESS), "sideways"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
