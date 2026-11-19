"""Unit tests for the pure helpers in the CPZ settings TUI.

The TUI itself needs curses and a terminal; everything tested here is the
policy that decides what gets written to ~/.config/cpz/settings.conf.
"""

from __future__ import annotations

import contextlib
import curses
import gzip
import importlib.util
import io
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime
from importlib.machinery import SourceFileLoader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "stage3" / "01-session" / "files" / "cpz-settings"

PERSISTED = (
    "keyboard_layout",
    "keyboard_layouts",
    "keyboard_layout_active",
    "theme",
    "language",
    "show_clock",
    "clock_24h",
    "show_date",
    "date_format",
    "show_battery",
    "show_volume",
    "show_brightness",
    "show_conn",
    "show_eth",
    "show_wifi",
    "show_bt",
    "show_layout",
    "display",
    "font_size",
    "brightness",
    "screen_timeout",
    "mouse",
    "history_limit",
    "mode_keys",
    "status_interval",
    "set_clipboard",
    "automatic_rename",
)


def load_settings_module():
    """Import the extension-less cpz-settings file as a module."""
    loader = SourceFileLoader("cpz_settings", str(SETTINGS))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class SettingsTUI(unittest.TestCase):
    def setUp(self):
        self.mod = load_settings_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)

        self.system = root / "etc" / "cpz" / "settings.conf"
        self.system.parent.mkdir(parents=True)
        self.themes = root / "etc" / "cpz" / "themes"
        self.themes.mkdir(parents=True)
        labels = {"cpz-campbell": "Campbell", "cpz-homebrew": "Homebrew"}
        for name, label in labels.items():
            (self.themes / (name + ".conf")).write_text(
                "# name: " + label + "\n", encoding="utf-8"
            )

        self.mod.SYSTEM_SETTINGS = str(self.system)
        self.mod.THEME_DIR = str(self.themes)
        self.mod.TROVE_INDEX_SYSTEM = str(
            root / "usr" / "share" / "cpz" / "trove-index.json"
        )
        self.mod.TROVE_APT_SNAPSHOT = str(
            root / "usr" / "share" / "cpz" / "apt-packages.txt.gz"
        )
        self.mod.TROVE_APT_SNAPSHOT_TXT = str(
            root / "usr" / "share" / "cpz" / "apt-packages.txt"
        )
        self.config_home = root / "home" / ".config"
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(self.config_home)
        self.addCleanup(self.restore_env, "XDG_CONFIG_HOME", old)

        self.cache_home = root / "home" / ".cache"
        old = os.environ.get("XDG_CACHE_HOME")
        os.environ["XDG_CACHE_HOME"] = str(self.cache_home)
        self.addCleanup(self.restore_env, "XDG_CACHE_HOME", old)

        self.state_home = root / "home" / ".local" / "state"
        old = os.environ.get("XDG_STATE_HOME")
        os.environ["XDG_STATE_HOME"] = str(self.state_home)
        self.addCleanup(self.restore_env, "XDG_STATE_HOME", old)

    def restore_env(self, name, old):
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old

    def write_user(self, text):
        path = Path(self.mod.user_settings_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_defaults_are_usable(self):
        data = self.mod.load_settings()
        self.assertEqual(data["theme"], "cpz-campbell")
        self.assertEqual(data["brightness"], 100)
        self.assertEqual(data["display"], "auto")
        self.assertEqual(data["font_size"], 12)
        self.assertEqual(data["language"], "en")
        self.assertEqual(data["mouse"], 1)
        self.assertEqual(data["set_clipboard"], 1)
        self.assertEqual(data["keyboard_layouts"], "us")
        self.assertEqual(data["keyboard_layout_active"], "us")
        self.assertEqual(self.mod.theme_label("cpz-homebrew"), "Homebrew")

    def test_system_locale_is_skipped_when_already_set(self):
        with mock.patch.object(
            self.mod, "locale_conf_value", return_value="uk_UA.UTF-8"
        ), mock.patch.object(self.mod.subprocess, "run") as run:
            self.assertTrue(self.mod.apply_system_locale("uk"))
            run.assert_not_called()

    def test_system_locale_uses_the_sudo_helper(self):
        with mock.patch.object(
            self.mod, "locale_conf_value", return_value="en_US.UTF-8"
        ), mock.patch.object(
            self.mod.os.path, "isfile", return_value=True
        ), mock.patch.object(
            self.mod.subprocess, "run", return_value=mock.Mock(returncode=0)
        ) as run:
            self.assertTrue(self.mod.apply_system_locale("uk"))
            run.assert_called_once()
            self.assertEqual(
                run.call_args.args[0],
                ["sudo", "-n", self.mod.LOCALE_HELPER, "uk"],
            )
            self.assertEqual(run.call_args.kwargs["timeout"], 10)

    def test_system_locale_failure_keeps_the_cpz_language(self):
        with mock.patch.object(
            self.mod, "locale_conf_value", return_value="en_US.UTF-8"
        ), mock.patch.object(
            self.mod.os.path, "isfile", return_value=True
        ), mock.patch.object(
            self.mod.subprocess, "run", return_value=mock.Mock(returncode=1)
        ), mock.patch.object(self.mod, "tmux") as tmux:
            self.assertFalse(self.mod.apply_language("uk"))
            self.assertEqual(self.mod.tr("Search"), "Пошук")
            tmux.assert_any_call(
                "set-environment", "-g", "LANG", "uk_UA.UTF-8"
            )

    def test_locale_helper_rejects_unknown_language(self):
        helper = ROOT / "stage3" / "01-session" / "files" / "cpz-locale-apply"
        result = subprocess.run(
            [str(helper), "xx"], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("usage:", result.stderr)

    def test_theme_names_with_unsupported_characters_are_ignored(self):
        # The renderers only accept [A-Za-z0-9_-], so Settings must not offer
        # a theme that would silently fall back to Campbell.
        (self.themes / "my.theme.conf").write_text(
            "# name: Bad\n", encoding="utf-8"
        )
        (self.themes / "bad name.conf").write_text(
            "# name: Bad\n", encoding="utf-8"
        )
        names = self.mod.available_themes()
        self.assertNotIn("my.theme", names)
        self.assertNotIn("bad name", names)
        self.assertIn("cpz-campbell", names)

    def test_user_file_overrides_system_file(self):
        self.system.write_text(
            'theme="cpz-homebrew"\nshow_clock=1\nbrightness=40\n', encoding="utf-8"
        )
        self.write_user("show_clock=0\nbrightness=1000\n")

        data = self.mod.load_settings()
        self.assertEqual(data["theme"], "cpz-homebrew")
        self.assertEqual(data["show_clock"], 0)
        # Values are clamped, not rejected.
        self.assertEqual(data["brightness"], 100)

    def test_invalid_values_fall_back_to_defaults(self):
        self.write_user(
            "display=sideways\n"
            "font_size=999\n"
            "history_limit=7\n"
            "mode_keys=weird\n"
            "screen_timeout=7\n"
            "status_interval=3\n"
            "brightness=1\n"
            "keyboard_layout=sideways\n"
        )

        data = self.mod.load_settings()
        self.assertEqual(data["display"], "auto")
        # Values are clamped, not rejected.
        self.assertEqual(data["font_size"], 64)
        self.assertEqual(data["history_limit"], 2000)
        self.assertEqual(data["mode_keys"], "vi")
        self.assertEqual(data["screen_timeout"], 0)
        self.assertEqual(data["status_interval"], 5)
        self.assertEqual(data["brightness"], 10)
        self.assertEqual(data["keyboard_layout"], "auto")

    def test_unknown_keys_are_ignored(self):
        self.write_user("unknown_key=42\ntheme=cpz-homebrew\n")
        data = self.mod.load_settings()
        self.assertEqual(data["theme"], "cpz-homebrew")
        self.assertNotIn("unknown_key", data)

    def test_save_and_load_round_trip(self):
        data = self.mod.load_settings()
        data.update(
            theme="cpz-homebrew",
            show_clock=0,
            date_format="iso",
            display="hdmi",
            font_size=18,
            brightness=55,
            keyboard_layouts="us,de,ua",
            keyboard_layout_active="ua",
            history_limit=5000,
            mode_keys="emacs",
            status_interval=1,
            screen_timeout=30,
        )

        self.mod.save_settings(data)

        path = Path(self.mod.user_settings_path())
        self.assertTrue(path.exists())
        self.assertFalse(Path(str(path) + ".tmp").exists())
        self.assertIn("# CPZ user settings", path.read_text(encoding="utf-8"))

        reloaded = self.mod.load_settings()
        for key in PERSISTED:
            self.assertEqual(reloaded[key], data[key], key)

    def test_legacy_font_presets_are_migrated(self):
        self.write_user("font_panel=8x16\n")
        self.assertEqual(self.mod.load_settings()["font_size"], 16)

        self.write_user("font_hdmi=20x40\n")
        self.assertEqual(self.mod.load_settings()["font_size"], 12)

        self.write_user("font_panel=8x16\nfont_size=22\n")
        self.assertEqual(self.mod.load_settings()["font_size"], 22)

    def test_font_size_choices_cover_the_key_bindings(self):
        self.assertEqual(self.mod.FONT_SIZE_MIN, 10)
        self.assertEqual(self.mod.FONT_SIZE_MAX, 64)
        self.assertIn(12, self.mod.FONT_SIZES)
        self.assertIn(16, self.mod.FONT_SIZES)
        self.assertIn(64, self.mod.FONT_SIZES)
        self.assertEqual(self.mod.FONT_SIZE_LABELS[14], "14px")

    def test_shortcut_filter_matches_label_or_binding(self):
        items = [
            {"label": "Next Tab"},
            {"label": "Settings"},
            {"label": "New Tab"},
        ]
        values = ["Alt+Tab", "Alt+S", "Alt+T"]
        self.assertEqual(self.mod.filter_item_indices(items, values, ""), [0, 1, 2])
        self.assertEqual(self.mod.filter_item_indices(items, values, "alt+s"), [1])
        self.assertEqual(self.mod.filter_item_indices(items, values, "tab"), [0, 2])
        self.assertEqual(self.mod.filter_item_indices(items, values, "nothing"), [])

    def test_shortcuts_page_is_filterable(self):
        # 37 rows do not fit the 53x14 panel, so the page must offer "/".
        self.assertIn("shortcuts", self.mod.FILTERABLE_PAGES)
        items = self.mod.shortcut_items(self.mod.load_settings())
        self.assertGreater(len(items), 20)

    def test_layouts_are_normalized_in_canonical_order(self):
        self.assertEqual(self.mod.normalize_layouts("de, us ,de,bogus"), ["us", "de"])
        self.assertEqual(
            self.mod.layout_codes({"keyboard_layouts": "ru,ua"}), ["ru", "ua"]
        )
        # An unknown active layout falls back to the first enabled one.
        self.assertEqual(
            self.mod.active_layout(
                {"keyboard_layouts": "us,de", "keyboard_layout_active": "fr"}
            ),
            "us",
        )

    def test_layouts_are_sorted_alphabetically(self):
        labels = [label for _code, label in self.mod.LAYOUTS]
        self.assertEqual(labels, sorted(labels, key=str.casefold))

    def test_timezones_keep_the_common_ones_first(self):
        zones = list(self.mod.TIMEZONES)
        common = [zone for zone in zones if zone in self.mod.COMMON_TIMEZONES]
        self.assertEqual(common, zones[: len(common)])
        rest = zones[len(common) :]
        self.assertEqual(rest, sorted(rest, key=str.lower))

    def test_modal_text_wraps_and_keeps_paragraphs(self):
        self.assertEqual(
            self.mod.modal_text("one two three\n\nfour", 9),
            ["one two", "three", "", "four"],
        )
        self.assertEqual(self.mod.modal_text("", 20), [""])

    def test_result_severity_selects_waiting_dialog(self):
        for message in (
            "Install failed (try sudo apt update)",
            "Cannot update manager state",
            "Could not disable NTP",
            "Not in apt; use the install instructions above",
            "Refused: would remove core packages",
        ):
            self.assertTrue(self.mod.message_is_error(message), message)
        for message in (
            "Installed htop",
            "Removed htop",
            "Settings reset",
            "Cancelled",
            "connected",
        ):
            self.assertFalse(self.mod.message_is_error(message), message)

    def test_datetime_helpers(self):
        parts = self.mod.datetime_parts(datetime(2026, 1, 31, 23, 59, 58))
        self.assertEqual(parts, [2026, 1, 31, 23, 59, 58])

        # Moving the month clamps the day to the new month length.
        self.mod.adjust_datetime_part(parts, 1, 1)
        self.assertEqual(parts[:3], [2026, 2, 28])

        self.mod.adjust_datetime_part(parts, 3, 1)
        self.assertEqual(parts[3], 0)

        self.mod.set_datetime_part_text(parts, 1, "13")
        self.assertEqual(parts[1], 12)
        self.mod.set_datetime_part_text(parts, 0, "1990")
        self.assertEqual(parts[0], 1990)
        self.mod.set_datetime_part_text(parts, 0, "99")
        self.assertEqual(parts[0], 1990)
        self.mod.set_datetime_part_text(parts, 2, "")
        self.assertEqual(parts[2], 28)

    def test_page_graph_is_consistent(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            rc = self.mod.check_pages()
        self.assertEqual(rc, 0)
        self.assertIn("pages OK", output.getvalue())
        self.assertGreater(len(self.mod.PAGE_TITLES), 10)

    def test_menu_labels_fit_the_value_column(self):
        data = dict(self.mod.DEFAULTS)
        for page in self.mod.PAGE_TITLES:
            for item in self.mod.page_items(page, data, None):
                self.assertLessEqual(
                    len(item["label"]), 16, f"{page}: {item['label']}"
                )

    def test_mouse_support_row_shows_state_and_detection(self):
        self.mod.set_language("en")
        with mock.patch.object(
            self.mod,
            "pointer_status",
            return_value={"mouse": "connected", "cursor": "visible"},
        ):
            self.assertEqual(
                self.mod.mouse_support_text({"mouse": 1}), "On · Connected"
            )
            self.assertEqual(
                self.mod.mouse_support_text({"mouse": 0}), "Off · Connected"
            )
        with mock.patch.object(
            self.mod,
            "pointer_status",
            return_value={"mouse": "disconnected", "cursor": "hidden"},
        ):
            self.assertEqual(
                self.mod.mouse_support_text({"mouse": 1}), "On · Not connected"
            )

    def test_input_page_owns_keyboard_and_mouse(self):
        data = dict(self.mod.DEFAULTS)
        self.assertEqual(self.mod.PAGE_TITLES["keyboard"], "Input")
        main_labels = [item["label"] for item in self.mod.page_items("main", data, None)]
        self.assertIn("Input", main_labels)
        self.assertNotIn("Keyboard", main_labels)
        input_labels = [
            item["label"] for item in self.mod.page_items("keyboard", data, None)
        ]
        self.assertIn("Mouse Support", input_labels)
        self.assertNotIn("Mouse", input_labels)
        self.assertNotIn("Cursor", input_labels)
        terminal_labels = [
            item["label"] for item in self.mod.page_items("terminal", data, None)
        ]
        self.assertNotIn("Mouse Support", terminal_labels)

    def test_mouse_page_geometry_maps_clicks_and_wheels(self):
        top, visible, first = self.mod.page_geometry(0, 10, 14)
        self.assertEqual((top, visible, first), (2, 11, 0))
        self.assertEqual(self.mod.page_row_at(2, top, first, visible, 10), 0)
        self.assertEqual(self.mod.page_row_at(11, top, first, visible, 10), 9)
        self.assertIsNone(self.mod.page_row_at(12, top, first, visible, 10))
        self.assertIsNone(self.mod.page_row_at(1, top, first, visible, 10))

        top, visible, first = self.mod.page_geometry(8, 10, 8)
        self.assertEqual((top, visible, first), (2, 5, 4))
        self.assertEqual(self.mod.page_row_at(2, top, first, visible, 10), 4)
        self.assertEqual(self.mod.page_row_at(6, top, first, visible, 10), 8)
        self.assertIsNone(self.mod.page_row_at(7, top, first, visible, 10))

        self.assertEqual(
            self.mod.mouse_wheel_delta(self.mod.MOUSE_BUTTON4_PRESSED), -3
        )
        self.assertEqual(
            self.mod.mouse_wheel_delta(self.mod.MOUSE_BUTTON5_PRESSED), 3
        )
        self.assertEqual(self.mod.mouse_wheel_delta(curses.BUTTON1_CLICKED), 0)

    def test_full_screen_pages_keep_a_side_gutter(self):
        # The panel is 53 columns. Every full-screen page leaves one blank
        # column on each side, so content gets 51.
        self.assertEqual(self.mod.SCREEN_PAD, 1)
        self.assertEqual(self.mod.content_width(53), 51)
        self.assertEqual(self.mod.content_width(80), 78)
        self.assertEqual(self.mod.content_width(1), 1)

    def test_status_bar_page_fits_the_panel(self):
        data = dict(self.mod.DEFAULTS)
        data.update(show_clock=1, show_date=1, show_conn=1)
        items = self.mod.page_items("statusbar", data, None)
        self.assertLessEqual(len(items), 11)

    def test_filter_rows_matches_labels_and_codes(self):
        rows = [("ua", "Ukrainian"), ("us", "English (US)")]
        self.assertEqual(self.mod.filter_rows(rows, "ukr"), [("ua", "Ukrainian")])
        self.assertEqual(self.mod.filter_rows(rows, "US"), [("us", "English (US)")])
        self.assertEqual(self.mod.filter_rows(rows, "zzz"), [])

    def test_apt_package_parsing(self):
        self.assertEqual(self.mod.apt_command_package("apt install tmux"), "tmux")
        self.assertEqual(
            self.mod.apt_command_package("sudo apt-get install -y bat"), "bat"
        )
        self.assertEqual(self.mod.apt_command_package("sudo -E apt install bat"), "bat")
        self.assertEqual(
            self.mod.apt_command_package(
                "DEBIAN_FRONTEND=noninteractive apt install bat"
            ),
            "bat",
        )
        self.assertEqual(
            self.mod.apt_command_package(
                "apt install -y --no-install-recommends htop"
            ),
            "htop",
        )
        self.assertEqual(self.mod.apt_command_package("apt install rust:arm64"), "rust")
        self.assertEqual(self.mod.apt_command_package("snap install foo"), "")
        self.assertEqual(self.mod.apt_command_package("apt install ./foo.deb"), "")

    def test_trove_index_loading_and_filters(self):
        index = {
            "schema": 1,
            "tools": [
                {
                    "slug": "tmux",
                    "name": "tmux",
                    "summary": "terminal multiplexer",
                    "language": "c",
                    "language_label": "C",
                    "categories": ["tui", "multiplexers"],
                    "platforms": ["linux"],
                    "install": {
                        "linux": {"ubuntu / debian": "apt install tmux"},
                    },
                    "apt": {"command": "apt install tmux", "package": "tmux"},
                },
                {
                    "slug": "lazygit",
                    "name": "lazygit",
                    "summary": "terminal UI for git",
                    "language": "go",
                    "language_label": "Go",
                    "categories": ["git", "tui"],
                    "platforms": ["linux"],
                    "install": {},
                    "apt": {},
                },
            ],
            "categories": [
                {"slug": "git", "name": "Git", "count": 1},
                {"slug": "tui", "name": "TUI", "count": 2},
            ],
            "languages": [
                {"slug": "c", "name": "C", "count": 1},
                {"slug": "go", "name": "Go", "count": 1},
            ],
        }
        path = Path(self.mod.trove_cache_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(__import__("json").dumps(index), encoding="utf-8")

        loaded = self.mod.load_trove_index()
        self.assertEqual(loaded["count"], 2)
        self.assertEqual(
            [tool["slug"] for tool in self.mod.filter_trove_tools(loaded["tools"])],
            ["tmux", "lazygit"],
        )
        self.assertEqual(
            [
                tool["slug"]
                for tool in self.mod.filter_trove_tools(
                    loaded["tools"], "git", "", ""
                )
            ],
            ["lazygit"],
        )
        self.assertEqual(
            [
                tool["slug"]
                for tool in self.mod.filter_trove_tools(
                    loaded["tools"], "", "tui", "c"
                )
            ],
            ["tmux"],
        )
        self.assertEqual(
            self.mod.trove_option_label(
                self.mod.trove_category_options(loaded), "tui"
            ),
            "TUI",
        )

    def test_trove_tool_list_for_search(self):
        index = {
            "schema": 1,
            "tools": [
                {
                    "slug": "tmux",
                    "name": "tmux",
                    "summary": "terminal multiplexer",
                    "categories": ["tui"],
                    "apt": {"command": "apt install tmux", "package": "tmux"},
                },
                {
                    "slug": "lazygit",
                    "name": "lazygit",
                    "summary": "terminal UI for git",
                    "categories": ["git"],
                    "apt": {},
                },
                {
                    "slug": "github-cli",
                    "name": "GitHub CLI",
                    "summary": "GitHub from the terminal",
                    "categories": ["git"],
                    "apt": {"command": "apt install gh", "package": "github-cli"},
                },
            ],
        }
        path = Path(self.mod.trove_cache_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(index), encoding="utf-8")
        self.mod.write_trove_apps(
            {
                "github-cli": {
                    "slug": "github-cli",
                    "name": "GitHub CLI",
                    "package": "github-cli",
                    "version": "2.0",
                    "installed_at": "2026-11-18T00:00:00",
                    "install_command": "apt install gh",
                    "uninstall_command": "apt-get purge github-cli",
                }
            }
        )

        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        for name in ("tmux", "gh"):
            binary = bindir / name
            binary.write_text("#!/bin/sh\n", encoding="utf-8")
            binary.chmod(0o755)
        old = os.environ.get("PATH")
        os.environ["PATH"] = str(bindir)
        self.addCleanup(self.restore_env, "PATH", old)
        self.mod.package_executables = lambda package: (
            ["gh"] if package == "github-cli" else []
        )

        payload = self.mod.list_tools_payload()
        self.assertEqual(payload["schema"], 1)
        tools = {tool["slug"]: tool for tool in payload["tools"]}
        self.assertEqual(tools["tmux"]["command"], "tmux")
        self.assertTrue(tools["tmux"]["installed"])
        self.assertFalse(tools["tmux"]["managed"])
        self.assertEqual(tools["tmux"]["apt"], "tmux")
        self.assertEqual(tools["lazygit"]["command"], "")
        self.assertFalse(tools["lazygit"]["installed"])
        self.assertFalse(tools["lazygit"]["managed"])
        self.assertEqual(tools["github-cli"]["command"], "gh")
        self.assertTrue(tools["github-cli"]["installed"])
        self.assertTrue(tools["github-cli"]["managed"])

    def test_trove_apt_support_filter(self):
        apt_names = {"tmux", "lazygit", "github-cli"}
        tools = [
            {
                "slug": "tmux",
                "name": "tmux",
                "apt": {"command": "apt install tmux", "package": "tmux"},
            },
            {"slug": "lazygit", "name": "lazygit", "apt": {}},
            {"slug": "github", "name": "GitHub CLI", "apt": {}},
            {
                "slug": "broken",
                "name": "broken",
                "apt": {"command": "apt install not-in-apt", "package": "not-in-apt"},
            },
        ]
        supported = [
            tool["slug"]
            for tool in self.mod.filter_trove_tools(tools, apt_names=apt_names)
        ]
        self.assertEqual(supported, ["tmux", "lazygit", "github"])
        # A catalog apt command is authoritative: do not silently fall back to
        # an unrelated package with the same slug/name.
        self.assertFalse(
            self.mod.trove_tool_apt_supported(tools[3], apt_names)
        )
        self.assertEqual(self.mod.filter_trove_tools(tools, apt_names=set()), [])

    def test_trove_apt_names_parses_commands(self):
        def fake_run(args, timeout=30):
            if "pkgnames" in args:
                return 0, "tmux\nfoo:arm64\nnot a package\n", ""
            return 0, "htop\n", ""

        self.mod.nm_run = fake_run
        self.assertEqual(
            self.mod.trove_apt_names(), {"tmux", "foo", "htop"}
        )

    def test_trove_apt_names_reads_build_snapshot(self):
        self.mod.nm_run = lambda args, timeout=30: (1, "", "")
        path = Path(self.mod.TROVE_APT_SNAPSHOT)
        path.parent.mkdir(parents=True, exist_ok=True)
        with gzip.open(path, "wt", encoding="utf-8") as handle:
            handle.write("tmux\nfoo:arm64\nbad name\n")
        self.assertEqual(self.mod.trove_apt_names(), {"tmux", "foo"})

    def test_resolve_trove_apt_uses_snapshot(self):
        self.mod.apt_status = lambda package: {
            "package": package,
            "status": "missing",
            "version": "",
        }
        self.mod.apt_lists_present = lambda: False
        tool = {
            "slug": "tmux",
            "name": "tmux",
            "apt": {"command": "apt install tmux", "package": "tmux"},
        }
        resolved = self.mod.resolve_trove_apt(tool, {"tmux"})
        self.assertEqual(resolved["status"], "available")
        self.assertEqual(resolved["needs_update"], "1")
        self.assertEqual(self.mod.resolve_trove_apt(tool, set())["status"], "missing")

    def test_cli_install_tool_records_the_app(self):
        index = {
            "schema": 1,
            "tools": [
                {
                    "slug": "btop",
                    "name": "btop",
                    "summary": "resource monitor",
                    "apt": {"command": "apt install btop", "package": "btop"},
                }
            ],
        }
        path = Path(self.mod.trove_cache_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(index), encoding="utf-8")
        self.mod.trove_apt_names = lambda: {"btop"}
        self.mod.resolve_trove_apt = lambda tool, names: {
            "package": "btop",
            "status": "available",
            "version": "",
        }
        self.mod.apt_status = lambda package: {
            "package": package,
            "status": "installed",
            "version": "1.0",
        }
        with mock.patch.object(self.mod.subprocess, "call", return_value=0):
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(self.mod.cli_install_tool("btop"), 0)
        apps = self.mod.read_trove_apps()
        self.assertEqual(apps["btop"]["package"], "btop")
        self.assertEqual(apps["btop"]["version"], "1.0")

    def test_cli_install_tool_rejects_unknown_slugs(self):
        self.assertEqual(self.mod.cli_install_tool("missing"), 2)

    def test_search_tool_target_opens_the_app_details(self):
        """CPZ Search's --tool target must land on the app page, not the list."""
        tool = {"slug": "lazygit", "name": "lazygit"}
        self.mod.draw_loading = lambda *_args, **_kwargs: None
        self.mod.load_trove_index = lambda: {
            "tools": [tool],
            "categories": [],
            "languages": [],
        }
        self.mod.read_trove_apps = lambda: {"lazygit": {"slug": "lazygit"}}
        self.mod.trove_apt_names = lambda: {"lazygit"}
        with mock.patch.object(self.mod, "trove_details_screen") as details:
            self.mod.trove_apps_screen(mock.Mock(), "lazygit")
        details.assert_called_once()
        self.assertEqual(details.call_args.args[1]["slug"], "lazygit")
        self.assertEqual(details.call_args.args[2], {"slug": "lazygit"})

    def test_trove_managed_state_round_trip(self):
        apps = {
            "tmux": {
                "slug": "tmux",
                "name": "tmux",
                "package": "tmux",
                "version": "3.4",
                "installed_at": "2026-11-17T12:00:00",
                "install_command": "apt install tmux",
                "uninstall_command": "apt-get purge tmux",
            }
        }
        self.mod.write_trove_apps(apps)
        self.assertEqual(self.mod.read_trove_apps(), apps)
        path = Path(self.mod.trove_state_path())
        self.assertEqual(oct(path.stat().st_mode & 0o777), "0o600")

    def test_trove_details_show_manual_instructions(self):
        tool = {
            "slug": "foo",
            "name": "foo",
            "summary": "a terminal foo",
            "description": "",
            "language": "rust",
            "language_label": "Rust",
            "categories": ["tui"],
            "platforms": ["linux"],
            "install": {
                "linux": {"ubuntu / debian": "snap install foo"},
                "macos": "brew install foo",
            },
            "apt": {},
            "url": "https://terminaltrove.com/foo/",
            "website": "https://example.com/foo",
        }
        lines = self.mod.trove_details_lines(
            tool,
            {"package": "", "status": "missing", "version": "", "source": "slug"},
            None,
            60,
        )
        text = "\n".join(lines)
        self.assertIn("Not available in apt", text)
        self.assertIn("snap install foo", text)
        self.assertIn("brew install foo", text)
        self.assertIn("Catalog: https://terminaltrove.com/foo/", text)
        self.assertIn("Website: https://example.com/foo", text)

    def test_trove_details_do_not_offer_system_packages(self):
        tool = {
            "slug": "htop",
            "name": "htop",
            "summary": "process viewer",
            "description": "",
            "language": "c",
            "language_label": "C",
            "categories": ["tui"],
            "platforms": ["linux"],
            "install": {},
            "apt": {},
            "url": "https://terminaltrove.com/htop/",
            "website": "",
        }
        lines = self.mod.trove_details_lines(
            tool,
            {
                "package": "htop",
                "status": "installed",
                "version": "3.4",
                "source": "catalog",
            },
            None,
            60,
        )
        text = "\n".join(lines)
        self.assertIn("installed (system)", text)
        self.assertIn("outside the manager", text)
        self.assertNotIn("Install: apt-get install", text)

    def test_newer_system_index_wins_over_stale_cache(self):
        old = {
            "schema": 1,
            "generated_at": "2026-01-01T00:00:00+00:00",
            "tools": [{"slug": "old", "name": "old"}],
        }
        new = {
            "schema": 1,
            "generated_at": "2026-02-01T00:00:00+00:00",
            "tools": [{"slug": "new", "name": "new"}],
        }
        cache = Path(self.mod.trove_cache_path())
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(__import__("json").dumps(old), encoding="utf-8")
        system = Path(self.mod.TROVE_INDEX_SYSTEM)
        system.parent.mkdir(parents=True, exist_ok=True)
        system.write_text(__import__("json").dumps(new), encoding="utf-8")
        self.assertEqual(self.mod.load_trove_index()["tools"][0]["slug"], "new")

    def test_trove_index_without_catalog_is_empty(self):
        loaded = self.mod.load_trove_index()
        self.assertEqual(loaded["tools"], [])
        self.assertEqual(loaded["count"], 0)


class ModalChrome(unittest.TestCase):
    """All dialogs share one frame, so title/padding/hint cannot drift."""

    def setUp(self):
        self.mod = load_settings_module()

        class FakePopup:
            def __init__(self, height, width):
                self.height = height
                self.width = width
                self.calls = []

            def getmaxyx(self):
                return self.height, self.width

            def erase(self):
                self.calls.append(("erase",))

            def attrset(self, attr):
                self.calls.append(("attrset", attr))

            def box(self):
                self.calls.append(("box",))

            def addstr(self, y, x, text, attr=0):
                self.calls.append((y, x, text, attr))

            def keypad(self, enabled):
                self.calls.append(("keypad", enabled))

            def refresh(self):
                self.calls.append(("refresh",))

        self.FakePopup = FakePopup

    def test_frame_places_bold_title_and_muted_hint(self):
        popup = self.FakePopup(8, 40)
        hint = "Enter/y yes  n/Esc cancel"
        self.mod.draw_modal_frame(popup, "Reboot", hint)
        self.assertIn(
            (
                0,
                self.mod.MODAL_TEXT_COLUMN,
                " Reboot ",
                self.mod.curses.A_BOLD,
            ),
            popup.calls,
        )
        self.assertIn(
            (
                6,
                self.mod.MODAL_TEXT_COLUMN,
                hint,
                self.mod.hint_attr(),
            ),
            popup.calls,
        )

    def test_danger_reverses_only_the_title(self):
        popup = self.FakePopup(8, 40)
        self.mod.draw_modal_frame(popup, "Reboot", "", error=True)
        self.assertIn(
            (
                0,
                self.mod.MODAL_TEXT_COLUMN,
                " Reboot ",
                self.mod.curses.A_REVERSE | self.mod.curses.A_BOLD,
            ),
            popup.calls,
        )

    def test_modal_window_body_starts_one_blank_row_below_the_border(self):
        class FakeScreen:
            def getmaxyx(self):
                return 14, 53

        popup = self.FakePopup(6, 24)
        with mock.patch.object(self.mod.curses, "newwin", return_value=popup):
            self.mod.modal_window(
                FakeScreen(),
                "Reboot",
                "Reboot now?",
                "Enter/y yes  n/Esc cancel",
            )
        self.assertIn(
            (2, self.mod.MODAL_TEXT_COLUMN, "Reboot now?", 0),
            popup.calls,
        )


if __name__ == "__main__":
    unittest.main()
