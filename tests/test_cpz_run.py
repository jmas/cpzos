"""Tests for the CPZ application environment wrapper."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
RUN = FILES / "cpz-run"


class RunWrapperTest(unittest.TestCase):
    def run_wrapper(self, env_text: str | None, args: list[str]):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env_file = root / "client.env"
            if env_text is not None:
                env_file.write_text(env_text, encoding="utf-8")
            script = root / "cpz-run"
            text = RUN.read_text(encoding="utf-8").replace(
                "/run/cpz-cage/client.env", str(env_file)
            )
            script.write_text(text, encoding="utf-8")
            script.chmod(0o755)
            env = os.environ.copy()
            env.pop("WAYLAND_DISPLAY", None)
            env.pop("DISPLAY", None)
            result = subprocess.run(
                [str(script)] + args,
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=30,
            )
            return result

    def test_applies_published_graphics_environment(self):
        result = self.run_wrapper(
            "WAYLAND_DISPLAY='wayland-9'\n"
            "DISPLAY=':7'\n"
            "XAUTHORITY='/run/user/1000/xauth'\n",
            ["/bin/sh", "-c", 'printf "%s %s %s" "$WAYLAND_DISPLAY" "$DISPLAY" "$XAUTHORITY"'],
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "wayland-9 :7 /run/user/1000/xauth")

    def test_runs_without_environment_file(self):
        result = self.run_wrapper(
            None, ["/bin/sh", "-c", 'printf "%s" "${WAYLAND_DISPLAY:-none}"']
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "none")

    def test_usage_without_command(self):
        result = self.run_wrapper("", [])
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)


if __name__ == "__main__":
    unittest.main()
