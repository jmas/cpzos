"""Unit tests for the CPZ Search (cpz-search) helpers.

The popup itself needs fzf and a terminal. These tests cover the providers,
item format, calculator and the Settings deep-link entry point.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SEARCH = ROOT / "stage3" / "01-session" / "files" / "cpz-search"
SETTINGS = ROOT / "stage3" / "01-session" / "files" / "cpz-settings"


def load_script(name: str, path: Path):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class SearchItems(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_search", SEARCH)
        self.mod.list_settings_pages = lambda: [("network", "Network")]
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        old = os.environ.get("CPZ_AUTOMOUNT_STATE")
        os.environ["CPZ_AUTOMOUNT_STATE"] = str(self.root / "automount")
        self.addCleanup(self.restore_env, "CPZ_AUTOMOUNT_STATE", old)

    def test_item_round_trip(self):
        item = self.mod.make_item("app", "vim", "vim  [app]", "", "installed")
        self.assertEqual(
            self.mod.parse_item(item),
            ("app", "vim", "vim  [app]", "", "installed"),
        )
        self.assertEqual(self.mod.item_flags(item), {"installed"})
        self.assertIsNone(self.mod.parse_item("not-an-item"))

    def test_control_characters_are_not_allowed_in_items(self):
        item = self.mod.make_item("app", "a\nb", "a\x1fb")
        parsed = self.mod.parse_item(item)
        assert parsed is not None
        kind, payload, display, extra, _flags = parsed
        self.assertEqual(kind, "app")
        self.assertEqual(extra, "")
        self.assertNotIn("\n", payload)
        self.assertNotIn("\x1f", display)
        self.assertFalse(self.mod.usable_text("a\nb"))
        self.assertTrue(self.mod.usable_text("plain text"))

    def test_default_items_have_actions_settings_and_apps(self):
        self.mod.list_settings_pages = lambda: [("network", "Network")]
        self.mod.scan_apps = lambda: ["less", "vim"]
        self.mod.trove_items = lambda: [
            self.mod.make_item(
                "tool",
                "fzf",
                "apps fzf  [run app]",
                "fzf",
                "managed,installed,runnable",
            ),
            self.mod.make_item(
                "tool",
                "lazygit",
                "apps lazygit  [install app]",
                "",
                "installable",
            ),
        ]
        self.mod.managed_app_items = lambda: [
            self.mod.make_item(
                "tool",
                "fzf",
                "fzf  [run app]",
                "fzf",
                "managed,installed,runnable",
            )
        ]
        parsed = [self.mod.parse_item(line) for line in self.mod.default_items()]
        kinds = [item[0] for item in parsed if item]
        self.assertIn("action", kinds)
        self.assertIn("settings", kinds)
        self.assertIn("app", kinds)
        self.assertIn(
            ("settings", "network", "Network  [settings]", "", "settings"),
            parsed,
        )
        self.assertIn(
            ("app", "vim", "vim  [app]", "", "installed,runnable"), parsed
        )
        payloads = [item[1] for item in parsed if item]
        self.assertEqual(payloads[0], "fzf")
        self.assertIn("lazygit", payloads)
        self.assertLess(payloads.index("fzf"), payloads.index("lazygit"))
        self.assertNotIn(("tool", "fzf", "apps fzf  [run app]", "fzf", "managed,installed,runnable"), parsed)

    def test_home_items_hold_settings_and_actions_when_no_apps_are_managed(self):
        self.mod.managed_app_items = lambda: []
        parsed = [self.mod.parse_item(line) for line in self.mod.home_items()]
        self.assertEqual(len(parsed), len(self.mod.ACTIONS) + 1)
        self.assertEqual(
            {item[0] for item in parsed if item}, {"action", "settings"}
        )
        self.assertEqual(parsed[0][0], "settings")
        self.assertEqual(
            parsed[0], ("settings", "network", "Network  [settings]", "", "settings")
        )

    def test_home_settings_rows_carry_the_searchable_page_title(self):
        self.mod.managed_app_items = lambda: []
        self.mod.list_settings_pages = lambda: [
            ("network", "Connections"),
            ("sound", "Sound"),
        ]
        displays = [
            (self.mod.parse_item(line) or ("", "", ""))[2]
            for line in self.mod.home_items()
        ]
        self.assertIn("Connections  [settings]", displays)
        self.assertIn("Sound  [settings]", displays)

    def test_home_prioritizes_managed_apps(self):
        self.mod.managed_app_items = lambda: [
            self.mod.make_item(
                "tool",
                "btop",
                "btop  [run app]",
                "btop",
                "managed,installed,runnable",
            )
        ]
        parsed = [self.mod.parse_item(line) for line in self.mod.home_items()]
        self.assertEqual(parsed[0][0], "tool")
        self.assertEqual(parsed[0][1], "btop")

    def test_media_items_read_the_automount_state(self):
        state = self.root / "state"
        state.mkdir()
        mount = self.root / "media" / "USB_STICK"
        mount.mkdir(parents=True)
        stale = self.root / "media" / "gone"
        stale.mkdir()
        (state / "sda1.mountpoint").write_text(f"{mount}\n", encoding="utf-8")
        (state / "sdb1.mountpoint").write_text(f"{stale}\n", encoding="utf-8")
        old = os.environ.get("CPZ_AUTOMOUNT_STATE")
        os.environ["CPZ_AUTOMOUNT_STATE"] = str(state)
        self.addCleanup(self.restore_env, "CPZ_AUTOMOUNT_STATE", old)

        self.mod.is_mounted = lambda path: path == str(mount)
        parsed = [self.mod.parse_item(line) for line in self.mod.media_items()]
        self.assertEqual(
            parsed,
            [
                (
                    "media",
                    "/dev/sda1",
                    f"Unmount USB_STICK  [media]  {mount}",
                    str(mount),
                    "media",
                )
            ],
        )

    def test_media_items_need_the_state_directory(self):
        old = os.environ.get("CPZ_AUTOMOUNT_STATE")
        os.environ["CPZ_AUTOMOUNT_STATE"] = str(self.root / "missing")
        self.addCleanup(self.restore_env, "CPZ_AUTOMOUNT_STATE", old)
        self.assertEqual(self.mod.media_items(), [])

    def test_home_lists_mounted_media_first(self):
        self.mod.managed_app_items = lambda: []
        self.mod.media_items = lambda: [
            self.mod.make_item(
                "media",
                "/dev/sda1",
                "Unmount USB_STICK  [media]  /media/USB_STICK",
                "/media/USB_STICK",
                "media",
            )
        ]
        parsed = [self.mod.parse_item(line) for line in self.mod.home_items()]
        self.assertEqual(parsed[0][0], "media")
        self.assertEqual(parsed[0][1], "/dev/sda1")
        self.assertIn("Enter unmount", self.mod.hint_line(self.mod.home_items()[0]))

    def test_hint_line_depends_on_the_selected_item(self):
        installed = self.mod.make_item(
            "tool", "btop", "btop  [run app]", "btop",
            "managed,installed,runnable",
        )
        missing = self.mod.make_item(
            "tool", "lazygit", "lazygit  [install app]", "",
            "installable",
        )
        self.assertIn("Enter run", self.mod.hint_line(installed))
        self.assertIn("Enter info", self.mod.hint_line(missing))
        self.assertIn("Type to search", self.mod.hint_line(""))

    def test_managed_apps_are_runnable_when_the_command_exists(self):
        self.mod.read_managed_apps = lambda: [
            {"slug": "btop", "name": "btop", "package": "btop", "version": "1"}
        ]
        self.mod.scan_apps = lambda: ["btop", "vim"]
        parsed = [
            self.mod.parse_item(line) for line in self.mod.managed_app_items()
        ]
        self.assertEqual(
            parsed[0],
            (
                "tool",
                "btop",
                "btop  [run app]",
                "btop",
                "managed,installed,runnable",
            ),
        )

    def test_managed_apps_without_a_command_stay_installed(self):
        self.mod.read_managed_apps = lambda: [
            {"slug": "foo", "name": "foo", "package": "foo", "version": "1"}
        ]
        self.mod.scan_apps = lambda: []
        self.mod.command_from_dpkg = lambda _package, _preferred=(): ""
        parsed = [
            self.mod.parse_item(line) for line in self.mod.managed_app_items()
        ]
        self.assertEqual(
            parsed[0],
            ("tool", "foo", "foo  [installed]", "", "managed,installed"),
        )

    def test_buffer_items_from_tmux(self):
        bindir = self.root / "bin"
        bindir.mkdir()
        fake = bindir / "tmux"
        fake.write_text(
            "#!/bin/sh\n"
            "case \"$1\" in\n"
            "  list-buffers) printf '0\\n1\\n' ;;\n"
            "  show-buffer) case \"$3\" in 0) printf 'git status\\n' ;; "
            "1) printf 'echo hi\\n' ;; esac ;;\n"
            "esac\n",
            encoding="utf-8",
        )
        fake.chmod(0o755)
        old_path = os.environ.get("PATH")
        old_tmux = os.environ.get("TMUX")
        os.environ["PATH"] = str(bindir)
        os.environ["TMUX"] = "1"
        self.addCleanup(self.restore_env, "PATH", old_path)
        self.addCleanup(self.restore_env, "TMUX", old_tmux)

        parsed = [self.mod.parse_item(line) for line in self.mod.buffer_items()]
        self.assertIn(("buffer", "0", "$0  [buf]  git status", "", ""), parsed)
        self.assertIn(("buffer", "1", "$1  [buf]  echo hi", "", ""), parsed)

    def restore_env(self, name, old):
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old

    def test_parse_trove_payload(self):
        payload = {
            "schema": 1,
            "tools": [
                {
                    "slug": "lazygit",
                    "name": "lazygit",
                    "summary": "",
                    "categories": ["git", "tui"],
                    "command": "",
                    "installed": False,
                    "apt": "lazygit",
                },
                {
                    "slug": "tmux",
                    "name": "tmux",
                    "summary": "terminal multiplexer",
                    "command": "tmux",
                    "installed": True,
                },
                {
                    "slug": "btop",
                    "name": "btop",
                    "summary": "resource monitor",
                    "command": "btop",
                    "installed": True,
                    "managed": True,
                },
                {
                    "slug": "bad\nslug",
                    "name": "bad name",
                    "command": "",
                },
            ],
        }
        items = [
            self.mod.parse_item(line)
            for line in self.mod.parse_trove_payload(json.dumps(payload))
        ]
        self.assertEqual(items[0][1], "btop")
        self.assertIn(
            (
                "tool",
                "tmux",
                "apps tmux  [run app]  terminal multiplexer",
                "tmux",
                "installed,runnable",
            ),
            items,
        )
        self.assertIn(
            (
                "tool",
                "lazygit",
                "apps lazygit  [install app]  git, tui",
                "",
                "installable",
            ),
            items,
        )
        self.assertEqual(len(items), 3)
        self.assertEqual(self.mod.parse_trove_payload("not json"), [])

    def test_search_roots_uses_the_override_and_existing_directories(self):
        missing = self.root / "missing"
        old = os.environ.get("CPZ_SEARCH_ROOTS")
        os.environ["CPZ_SEARCH_ROOTS"] = (
            f"{self.root}{os.pathsep}{missing}"
        )
        if old is None:
            self.addCleanup(os.environ.pop, "CPZ_SEARCH_ROOTS", None)
        else:
            self.addCleanup(os.environ.__setitem__, "CPZ_SEARCH_ROOTS", old)
        self.assertEqual(self.mod.search_roots(), [str(self.root)])

    def test_file_items_skip_pruned_directories(self):
        (self.root / "notes.txt").write_text("hello", encoding="utf-8")
        (self.root / "sub").mkdir()
        (self.root / "sub" / "app.py").write_text("pass", encoding="utf-8")
        (self.root / ".git").mkdir()
        (self.root / ".git" / "config").write_text("x", encoding="utf-8")

        old = os.environ.get("CPZ_SEARCH_ROOTS")
        os.environ["CPZ_SEARCH_ROOTS"] = str(self.root)
        if old is None:
            self.addCleanup(os.environ.pop, "CPZ_SEARCH_ROOTS", None)
        else:
            self.addCleanup(os.environ.__setitem__, "CPZ_SEARCH_ROOTS", old)

        parsed = [
            self.mod.parse_item(line) for line in self.mod.file_items()
        ]
        payloads = {item[1] for item in parsed if item}
        self.assertIn(str(self.root / "notes.txt"), payloads)
        self.assertIn(str(self.root / "sub"), payloads)
        self.assertIn(str(self.root / "sub" / "app.py"), payloads)
        self.assertNotIn(str(self.root / ".git" / "config"), payloads)

        directories = [
            item for item in parsed if item and item[1] == str(self.root / "sub")
        ]
        self.assertEqual(len(directories), 1)
        self.assertTrue(directories[0][2].endswith("[dir]"))


class Calculator(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_search_calc", SEARCH)

    def test_safe_eval(self):
        cases = {
            "2+2*3": 8,
            "(2+2)*3": 12,
            "2**10": 1024,
            "10/4": 2.5,
            "-5 % 3": 1,
            "2.5*2": 5.0,
        }
        for expression, expected in cases.items():
            self.assertEqual(self.mod.safe_eval(expression), expected)

    def test_safe_eval_rejects_code_and_huge_exponents(self):
        for expression in (
            "__import__('os')",
            "open('/etc/passwd')",
            "True",
            "1+2j",
            "2**999",
            "",
        ):
            with self.assertRaises(ValueError):
                self.mod.safe_eval(expression)

    def test_calc_item(self):
        self.assertEqual(self.mod.parse_item(self.mod.calc_item("=2+2"))[1], "4")
        self.assertIn("=2+2 = 4", self.mod.parse_item(self.mod.calc_item("=2+2"))[2])
        self.assertEqual(self.mod.parse_item(self.mod.calc_item("=2**999"))[1], "")
        self.assertIn("invalid", self.mod.parse_item(self.mod.calc_item("=2**999"))[2])
        self.assertEqual(self.mod.parse_item(self.mod.calc_item("="))[1], "")

    def test_check_runs(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.mod.check(), 0)


class ModeSwitch(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_search_mode", SEARCH)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.code = self.mod.mode_bind(self.tmp.name).split(
            "change:transform:", 1
        )[1]

    def run_mode(self, state: str, query: str):
        mode_path = Path(self.tmp.name) / "mode"
        mode_path.write_text(state, encoding="utf-8")
        result = subprocess.run(
            ["sh", "-c", self.code],
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "FZF_QUERY": query},
        )
        return result.stdout, mode_path.read_text(encoding="utf-8")

    def test_prefixes_reload_the_right_provider(self):
        output, state = self.run_mode("default", "=2")
        self.assertIn("--calc-file", output)
        self.assertEqual(state, "calc")

        output, state = self.run_mode("calc", "2")
        self.assertIn("--default", output)
        self.assertEqual(state, "default")

        output, state = self.run_mode("default", "/")
        self.assertIn("--files", output)
        self.assertEqual(state, "files")

        output, state = self.run_mode("files", "/notes")
        self.assertEqual(output, "")
        self.assertEqual(state, "files")

        output, state = self.run_mode("default", "apps")
        self.assertIn("--apps", output)
        self.assertEqual(state, "apps")

        output, state = self.run_mode("default", "apps btop")
        self.assertIn("--apps", output)
        self.assertEqual(state, "apps")

        output, state = self.run_mode("apps", "btop")
        self.assertIn("--default", output)
        self.assertEqual(state, "default")

        output, state = self.run_mode("default", "$")
        self.assertIn("--buffers", output)
        self.assertEqual(state, "buffers")

        output, state = self.run_mode("buffers", "$tmux")
        self.assertEqual(output, "")
        self.assertEqual(state, "buffers")

    def test_empty_query_shows_the_short_action_list(self):
        output, state = self.run_mode("default", "")
        self.assertIn("--home", output)
        self.assertEqual(state, "home")

        output, state = self.run_mode("home", "v")
        self.assertIn("--default", output)
        self.assertEqual(state, "default")

        output, state = self.run_mode("home", "")
        self.assertEqual(output, "")
        self.assertEqual(state, "home")


class Dispatch(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_search_dispatch", SEARCH)

    def test_tool_runs_an_installed_command(self):
        with mock.patch.object(self.mod, "launch") as launch:
            self.mod.dispatch("tool", "tmux", "", "/tmp", "tmux")
        launch.assert_called_once_with(["tmux"], "/tmp")

    def test_installable_tool_opens_the_catalog_details(self):
        with mock.patch.object(self.mod, "open_settings") as open_settings:
            self.mod.dispatch("tool", "lazygit", "", "/tmp", "")
        open_settings.assert_called_once_with("--tool", "lazygit")

    def test_installed_tool_without_command_opens_the_catalog_details(self):
        with mock.patch.object(self.mod, "open_settings") as open_settings:
            self.mod.dispatch("tool", "lazygit", "", "/tmp", "")
        open_settings.assert_called_once_with("--tool", "lazygit")

    def test_settings_page_opens_in_the_settings_tab(self):
        with mock.patch.object(self.mod, "open_settings") as open_settings:
            self.mod.dispatch("settings", "network", "", "/tmp")
        open_settings.assert_called_once_with("--page", "network")

    def test_ctrl_o_on_a_tool_opens_the_catalog_details(self):
        with mock.patch.object(self.mod, "open_settings") as open_settings:
            self.mod.dispatch("tool", "lazygit", "ctrl-o", "/tmp", "")
        open_settings.assert_called_once_with("--tool", "lazygit")

    def test_buffer_enter_pastes(self):
        with mock.patch.object(self.mod, "paste_buffer") as paste:
            self.mod.dispatch("buffer", "0", "", "/tmp")
        paste.assert_called_once_with("0")

    def test_media_enter_unmounts(self):
        with mock.patch.object(self.mod, "unmount_media") as unmount:
            self.mod.dispatch("media", "/dev/sda1", "", "/tmp", "/media/USB")
        unmount.assert_called_once_with("/dev/sda1", "/media/USB")


class MediaUnmount(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_search_media", SEARCH)

    def test_uses_sudo_and_the_automount_helper(self):
        completed = subprocess.CompletedProcess([], 0)
        with mock.patch.object(
            self.mod.shutil, "which", return_value="/usr/bin/sudo"
        ), mock.patch.object(
            self.mod, "helper", return_value="/usr/local/bin/cpz-automount"
        ), mock.patch.object(
            self.mod.subprocess, "run", return_value=completed
        ) as run, mock.patch.object(self.mod, "notify") as notify:
            self.mod.unmount_media("/dev/sda1", "/media/USB")
        run.assert_called_once_with(
            ["/usr/bin/sudo", "/usr/local/bin/cpz-automount", "umount", "/dev/sda1"],
            check=False,
        )
        notify.assert_called_once_with("Unmounted USB")

    def test_failure_is_reported(self):
        completed = subprocess.CompletedProcess([], 1)
        with mock.patch.object(
            self.mod.shutil, "which", return_value="/usr/bin/sudo"
        ), mock.patch.object(
            self.mod, "helper", return_value="/usr/local/bin/cpz-automount"
        ), mock.patch.object(
            self.mod.subprocess, "run", return_value=completed
        ), mock.patch.object(self.mod, "notify") as notify:
            self.mod.unmount_media("/dev/sda1", "/media/USB")
        notify.assert_called_once_with("cpz-search: cannot unmount USB")


class SettingsDeepLink(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_settings_search", SETTINGS)

    def test_initial_stack(self):
        self.assertEqual(self.mod.initial_stack(None, {}), [("main", 0)])
        self.assertEqual(self.mod.initial_stack("display", {}), [("display", 0)])
        self.assertEqual(self.mod.initial_stack("unknown", {}), [("main", 0)])

    def test_list_pages_cli(self):
        result = subprocess.run(
            [sys.executable, str(SETTINGS), "--list-pages"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0)
        pages = dict(
            line.split("\t", 1) for line in result.stdout.splitlines() if "\t" in line
        )
        self.assertEqual(pages.get("network"), "Connections")
        self.assertEqual(pages.get("main"), "Settings")

    def test_unknown_page_is_rejected_before_the_tty_check(self):
        result = subprocess.run(
            [sys.executable, str(SETTINGS), "--page", "missing"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown page", result.stderr)


class OpenSettings(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_search_settings", SEARCH)

    def test_uses_the_settings_tab_inside_tmux(self):
        with mock.patch.dict(os.environ, {"TMUX": "1"}), mock.patch.object(
            self.mod.shutil, "which", return_value="/usr/bin/tmux"
        ), mock.patch.object(
            self.mod, "helper", return_value="/usr/local/bin/cpz-settings-open"
        ), mock.patch.object(
            self.mod.os, "access", return_value=True
        ), mock.patch.object(
            self.mod, "run_hidden", return_value=True
        ) as run_hidden:
            self.mod.open_settings("--page", "network")
        run_hidden.assert_called_once_with(
            ["/usr/local/bin/cpz-settings-open", "--page", "network", "main"]
        )

    def test_falls_back_to_the_tui_outside_tmux(self):
        environment = {key: value for key, value in os.environ.items() if key != "TMUX"}
        with mock.patch.dict(os.environ, environment, clear=True), mock.patch.object(
            self.mod, "exec_settings"
        ) as exec_settings:
            self.mod.open_settings("--page", "network")
        exec_settings.assert_called_once_with("--page", "network")


class PopupChrome(unittest.TestCase):
    """The tmux popup draws the frame, so fzf must not draw a second one.

    A nested fzf border plus its separator showed up as extra ASCII lines in
    the middle of the Search window and ate four rows and columns of results.
    """

    def setUp(self):
        self.mod = load_script("cpz_search_chrome", SEARCH)
        self.arguments = self.mod.fzf_args("/tmp/cpz-search")

    def test_fzf_draws_no_second_frame(self):
        self.assertIn("--no-border", self.arguments)
        self.assertIn("--no-separator", self.arguments)
        borders = [
            argument
            for argument in self.arguments
            if argument.startswith("--border")
        ]
        self.assertEqual(borders, [])

    def test_footer_preview_stays_chromeless(self):
        preview = next(
            argument
            for argument in self.arguments
            if argument.startswith("--preview-window=")
        )
        self.assertIn("border-none", preview)


class SettingsRequests(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_settings_requests", SETTINGS)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "settings-request"
        old = os.environ.get("CPZ_SETTINGS_REQUEST")
        os.environ["CPZ_SETTINGS_REQUEST"] = str(self.path)
        if old is None:
            self.addCleanup(os.environ.pop, "CPZ_SETTINGS_REQUEST", None)
        else:
            self.addCleanup(os.environ.__setitem__, "CPZ_SETTINGS_REQUEST", old)

    def test_take_request_claims_the_file_once(self):
        self.path.write_text("page\nnetwork\n", encoding="utf-8")
        self.assertEqual(self.mod.take_request(), ("page", "network"))
        self.assertIsNone(self.mod.take_request())

    def test_take_request_rejects_incomplete_files(self):
        self.path.write_text("page\n", encoding="utf-8")
        self.assertIsNone(self.mod.take_request())
        self.path.write_text("bogus\nnetwork\n", encoding="utf-8")
        self.assertIsNone(self.mod.take_request())
        self.assertIsNone(self.mod.take_request())


if __name__ == "__main__":
    unittest.main()
