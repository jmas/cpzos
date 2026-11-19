"""Status-bar token tests for cpz-status."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STATUS = ROOT / "stage3" / "01-session" / "files" / "cpz-status"


class StatusTokens(unittest.TestCase):
    def run_status(self, conn: str, **overrides: int) -> str:
        settings = {
            "show_conn": 1,
            "show_layout": 0,
            "show_battery": 0,
            "show_volume": 0,
            "show_brightness": 0,
            "show_clock": 0,
            "show_date": 0,
        }
        settings.update(overrides)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "config" / "cpz"
            config.mkdir(parents=True)
            (config / "settings.conf").write_text(
                "".join(f"{key}={value}\n" for key, value in settings.items()),
                encoding="utf-8",
            )
            state = root / "cpz-conn"
            state.write_text(conn + "\n", encoding="utf-8")
            env = os.environ.copy()
            env["XDG_CONFIG_HOME"] = str(root / "config")
            env["CPZ_CONN_FILE"] = str(state)
            env["CPZ_THEME_DIR"] = str(root / "themes")
            result = subprocess.run(
                ["sh", str(STATUS)],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_enabled_and_connected_tokens_are_distinct(self):
        self.assertEqual(
            self.run_status("E E+ W W+ B B+"),
            "Et+ Wi Wi+ Bt Bt+",
        )

    def test_idle_enabled_wifi_and_bluetooth_stay_visible(self):
        self.assertEqual(self.run_status("W B"), "Wi Bt")

    def test_idle_ethernet_is_hidden(self):
        self.assertEqual(self.run_status("E"), "")
        self.assertEqual(self.run_status("E+"), "Et+")

    def test_network_switch_hides_the_whole_group(self):
        self.assertEqual(self.run_status("E+ W W+ B B+", show_conn=0), "")


if __name__ == "__main__":
    unittest.main()
