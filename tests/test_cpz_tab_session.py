"""Host-side tests for closing the last terminal tab.

The helpers only talk to tmux, so a fake tmux records the commands they would
run. Closing a terminal tab must be allowed even when it is the last one, while
the Settings tab stays open and last.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"

TMUX = """#!/bin/sh
printf '%s\\n' "$*" >>"$FAKE_TMUX_LOG"
if [ -n "${FAKE_FAIL:-}" ] && [ "$1" = "$FAKE_FAIL" ]; then exit 12; fi
case "$1" in
	has-session) exit "${FAKE_HAS_SESSION:-0}" ;;
	show-options) printf '0\\n' ;;
	list-windows) printf '%s\\n' "$FAKE_WINDOWS" ;;
	list-clients) printf 'client\\n' ;;
esac
exit 0
"""


class TabSessionTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bindir = self.root / "bin"
        self.bindir.mkdir()
        self.fake(self.bindir, "tmux", TMUX)
        self.log = self.root / "tmux.log"

    def fake(self, directory: Path, name: str, body: str) -> None:
        path = directory / name
        path.write_text(body, encoding="utf-8")
        path.chmod(0o755)

    def env(self, **values):
        environment = os.environ.copy()
        environment.update(
            {
                "PATH": f"{self.bindir}:{os.environ['PATH']}",
                "FAKE_TMUX_LOG": str(self.log),
                "FAKE_WINDOWS": "",
            }
        )
        environment.update(values)
        return environment

    def run_helper(self, name: str, *arguments: str, **values):
        return subprocess.run(
            ["sh", str(FILES / name), *arguments],
            capture_output=True,
            text=True,
            env=self.env(**values),
            check=False,
        )

    def commands(self) -> list[str]:
        if not self.log.exists():
            return []
        return self.log.read_text(encoding="utf-8").splitlines()

    def test_close_key_prompts_for_the_last_terminal_tab(self):
        result = self.run_helper(
            "cpz-tab-close-key", "main", FAKE_WINDOWS="@1 1 1 0 shell"
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assertTrue(
            any(command.startswith("confirm-before ") for command in commands)
        )
        self.assertFalse(
            any("Last tab stays open" in command for command in commands)
        )

    def test_close_key_keeps_settings_open(self):
        self.run_helper(
            "cpz-tab-close-key", "main", FAKE_WINDOWS="@1 1 1 1 settings"
        )
        commands = self.commands()
        self.assertIn("display-message -c client -d 3000 Settings stays open", commands)
        self.assertFalse(
            any(command.startswith("confirm-before ") for command in commands)
        )

    def test_close_kills_the_last_terminal_tab(self):
        self.run_helper(
            "cpz-tab-close", "main", FAKE_WINDOWS="@1 1 1 0 shell"
        )
        commands = self.commands()
        self.assertIn("kill-window -t @1", commands)
        self.assertFalse(
            any("Last tab stays open" in command for command in commands)
        )

    def test_close_never_kills_settings(self):
        self.run_helper(
            "cpz-tab-close", "main", FAKE_WINDOWS="@1 1 1 1 settings"
        )
        commands = self.commands()
        self.assertFalse(any(command.startswith("kill-window") for command in commands))
        self.assertIn("display-message -c client -d 3000 Settings stays open", commands)

    def test_session_ensure_does_not_recreate_a_shell_after_the_last_tab(self):
        self.run_helper(
            "cpz-session-ensure",
            "main",
            FAKE_WINDOWS="1 @1 0 1 settings",
        )
        commands = self.commands()
        self.assertFalse(
            any(command.startswith("new-window") for command in commands)
        )
        self.assertIn("set-option -w -t @1 @cpz_settings 1", commands)

    def test_session_ensure_stays_quiet_when_tmux_commands_fail(self):
        # tmux shows "'...' returned N" in the status bar for a non-zero hook.
        # A window race must not look like a boot error.
        result = self.run_helper(
            "cpz-session-ensure",
            "main",
            FAKE_WINDOWS="1 @1 0 1 settings\n2 @2 1 0 shell",
            FAKE_FAIL="swap-window",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")

        result = self.run_helper(
            "cpz-session-ensure",
            "main",
            FAKE_WINDOWS="1 @1 1 0 shell",
            FAKE_FAIL="list-windows",
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_tab_cycle_moves_between_live_tabs(self):
        windows = (
            "@1 1 1 0 shell\n"
            "@2 2 0 0 one\n"
            "@3 3 0 0 two\n"
            "@4 4 0 0 settings"
        )
        self.run_helper("cpz-tab-cycle", "main", "next", FAKE_WINDOWS=windows)
        self.assertIn("switch-client -c client -t @2", self.commands())

    def test_tab_cycle_includes_settings_and_wraps(self):
        windows = (
            "@1 1 0 0 shell\n"
            "@2 2 0 0 one\n"
            "@3 3 1 0 two\n"
            "@4 4 0 0 settings"
        )
        self.run_helper("cpz-tab-cycle", "main", "next", FAKE_WINDOWS=windows)
        self.assertIn("switch-client -c client -t @4", self.commands())

        # From Settings, Tab continues at the start of the list, and
        # Alt+Shift+Tab goes back to the previous tab.
        settings_active = (
            "@1 1 0 0 shell\n"
            "@2 2 0 0 one\n"
            "@3 3 0 0 two\n"
            "@4 4 1 0 settings"
        )
        self.log.write_text("", encoding="utf-8")
        self.run_helper(
            "cpz-tab-cycle", "main", "next", FAKE_WINDOWS=settings_active
        )
        self.assertIn("switch-client -c client -t @1", self.commands())

        self.log.write_text("", encoding="utf-8")
        self.run_helper(
            "cpz-tab-cycle", "main", "prev", FAKE_WINDOWS=settings_active
        )
        self.assertIn("switch-client -c client -t @3", self.commands())

    def test_tab_cycle_skips_dead_panes(self):
        windows = (
            "@1 1 1 0 shell\n"
            "@2 2 0 1 one\n"
            "@3 3 0 0 two\n"
            "@4 4 0 0 settings"
        )
        self.run_helper("cpz-tab-cycle", "main", "next", FAKE_WINDOWS=windows)
        self.assertIn("switch-client -c client -t @3", self.commands())

    def test_tab_cycle_toggles_between_one_tab_and_settings(self):
        windows = "@1 1 1 0 shell\n@2 2 0 0 settings"
        self.run_helper("cpz-tab-cycle", "main", "next", FAKE_WINDOWS=windows)
        self.assertIn("switch-client -c client -t @2", self.commands())

        self.log.write_text("", encoding="utf-8")
        windows = "@1 1 0 0 shell\n@2 2 1 0 settings"
        self.run_helper("cpz-tab-cycle", "main", "prev", FAKE_WINDOWS=windows)
        self.assertIn("switch-client -c client -t @1", self.commands())

    def test_tab_cycle_is_a_no_op_with_one_tab(self):
        windows = "@1 1 1 0 shell"
        self.run_helper("cpz-tab-cycle", "main", "next", FAKE_WINDOWS=windows)
        self.assertFalse(
            any(command.startswith("switch-client") for command in self.commands())
        )
        self.assertFalse(
            any(command.startswith("select-window") for command in self.commands())
        )


if __name__ == "__main__":
    unittest.main()
