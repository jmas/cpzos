"""Unit tests for the pure helpers in the CPZ settings TUI.

The TUI itself needs curses and a terminal; everything tested here is the
policy that decides what gets written to ~/.config/cpz/settings.conf.
"""

from __future__ import annotations

import contextlib
import gzip
import importlib.util
import io
import json
import os
import tempfile
import unittest
from datetime import datetime
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SETTINGS = ROOT / "stage3" / "01-session" / "files" / "cpz-settings"

PERSISTED = (
    "keyboard_layout",
    "keyboard_layouts",
    "keyboard_layout_active",
    "theme",
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
        self.assertEqual(data["keyboard_layouts"], "us")
        self.assertEqual(data["keyboard_layout_active"], "us")
        self.assertEqual(self.mod.theme_label("cpz-homebrew"), "Homebrew")

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
            ],
        }
        path = Path(self.mod.trove_cache_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(index), encoding="utf-8")

        bindir = Path(self.tmp.name) / "bin"
        bindir.mkdir()
        tmux = bindir / "tmux"
        tmux.write_text("#!/bin/sh\n", encoding="utf-8")
        tmux.chmod(0o755)
        old = os.environ.get("PATH")
        os.environ["PATH"] = str(bindir)
        self.addCleanup(self.restore_env, "PATH", old)

        payload = self.mod.list_tools_payload()
        self.assertEqual(payload["schema"], 1)
        tools = {tool["slug"]: tool for tool in payload["tools"]}
        self.assertEqual(tools["tmux"]["command"], "tmux")
        self.assertTrue(tools["tmux"]["installed"])
        self.assertEqual(tools["tmux"]["apt"], "tmux")
        self.assertEqual(tools["lazygit"]["command"], "")
        self.assertFalse(tools["lazygit"]["installed"])

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
        self.assertIn("Terminal Trove: https://terminaltrove.com/foo/", text)
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


if __name__ == "__main__":
    unittest.main()
