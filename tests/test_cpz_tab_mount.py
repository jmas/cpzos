"""Host-side tests for the cpz-tab-mount helper.

The helper only talks to tmux, so the tests run it against a fake tmux in PATH.
The root re-exec path (``runuser``) is exercised on the device, not here.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "stage3" / "01-session" / "files" / "cpz-tab-mount"

# $1 is the tmux subcommand. list-windows prints the two-field window table,
# list-panes reads "$FAKE_PANE_DIR/<window id>".
TMUX = """#!/bin/sh
printf '%s\\n' "$*" >>"$FAKE_TMUX_LOG"
case "$1" in
	has-session) exit "${FAKE_HAS_SESSION:-0}" ;;
	list-windows) printf '%s\\n' "$FAKE_WINDOWS" ;;
	list-panes) cat "$FAKE_PANE_DIR/$3" 2>/dev/null || true ;;
esac
exit 0
"""


class TabMountTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bindir = self.root / "bin"
        self.bindir.mkdir()
        fake(self.bindir, "tmux", TMUX)
        self.tmux_log = self.root / "tmux.log"
        self.tab_log = self.root / "tab.log"
        self.tab_new = self.root / "cpz-tab-new"
        self.tab_new.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >"$FAKE_TAB_LOG"\n'
            'printf "%s\\n" "${CPZ_TAB_MOUNT:-}" >>"$FAKE_TAB_LOG"\n',
            encoding="utf-8",
        )
        self.tab_new.chmod(0o755)
        self.mount = self.root / "media" / "USB_STICK"
        self.mount.mkdir(parents=True)

    def env(self, **values):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bindir}:{os.environ['PATH']}",
                "CPZ_TAB_NEW": str(self.tab_new),
                "FAKE_TMUX_LOG": str(self.tmux_log),
                "FAKE_TAB_LOG": str(self.tab_log),
                "FAKE_WINDOWS": "",
            }
        )
        environment.update(values)
        return environment

    def run_helper(self, *args, **values):
        return subprocess.run(
            ["sh", str(SCRIPT), *args],
            capture_output=True,
            text=True,
            env=self.env(**values),
            check=False,
        )

    def test_open_uses_the_mountpoint_and_a_short_label(self):
        result = self.run_helper(
            "open", str(self.mount), "A" * 40
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        arguments, tab_mount = self.tab_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(arguments, f"main {self.mount} {'A' * 16}")
        self.assertEqual(tab_mount, str(self.mount))

    def test_open_does_nothing_without_a_session(self):
        result = self.run_helper(
            "open", str(self.mount), "USB", FAKE_HAS_SESSION="1"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.tab_log.exists())

    def test_open_requires_the_mountpoint_to_exist(self):
        result = self.run_helper("open", str(self.root / "missing"), "USB")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.tab_log.exists())

    def test_close_kills_only_tabs_still_on_the_disk(self):
        panes = self.root / "panes"
        panes.mkdir()
        (panes / "@1").write_text(f"{self.mount}/photos\n", encoding="utf-8")
        (panes / "@2").write_text(f"{self.mount}\n", encoding="utf-8")
        (panes / "@3").write_text("/home/cpz\n", encoding="utf-8")
        (panes / "@4").write_text("/media/OTHER\n", encoding="utf-8")
        windows = "\n".join(
            [
                f"@1 {self.mount}",
                f"@2 {self.mount}",
                f"@3 {self.mount}",
                "@4 /media/OTHER",
            ]
        )
        result = self.run_helper(
            "close",
            str(self.mount),
            FAKE_WINDOWS=windows,
            FAKE_PANE_DIR=str(panes),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.tmux_log.read_text(encoding="utf-8")
        self.assertIn("kill-window -t @1", log)
        self.assertIn("kill-window -t @2", log)
        # The user moved out of the disk: keep that shell open.
        self.assertNotIn("kill-window -t @3", log)
        self.assertNotIn("kill-window -t @4", log)

    def test_usage_errors(self):
        result = self.run_helper("open")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        result = self.run_helper("sideways", str(self.mount))
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown action", result.stderr)


def fake(directory: Path, name: str, body: str) -> None:
    path = directory / name
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)


if __name__ == "__main__":
    unittest.main()
