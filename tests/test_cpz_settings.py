"""Unit tests for the pure helpers in the CPZ settings TUI.

The TUI itself needs curses and a terminal; everything tested here is the
policy that decides what gets written to ~/.config/cpz/settings.conf.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
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
    "font_panel",
    "font_hdmi",
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
        self.config_home = root / "home" / ".config"
        old = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(self.config_home)
        self.addCleanup(self.restore_env, old)

    def restore_env(self, old):
        if old is None:
            os.environ.pop("XDG_CONFIG_HOME", None)
        else:
            os.environ["XDG_CONFIG_HOME"] = old

    def write_user(self, text):
        path = Path(self.mod.user_settings_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")

    def test_defaults_are_usable(self):
        data = self.mod.load_settings()
        self.assertEqual(data["theme"], "cpz-campbell")
        self.assertEqual(data["brightness"], 100)
        self.assertEqual(data["display"], "auto")
        self.assertEqual(data["font_panel"], "6x12")
        self.assertEqual(data["font_hdmi"], "auto")
        self.assertEqual(data["keyboard_layouts"], "us")
        self.assertEqual(data["keyboard_layout_active"], "us")
        self.assertEqual(self.mod.theme_label("cpz-homebrew"), "Homebrew")

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
            "font_panel=9x9\n"
            "font_hdmi=9x9\n"
            "history_limit=7\n"
            "mode_keys=weird\n"
            "screen_timeout=7\n"
            "status_interval=3\n"
            "brightness=1\n"
            "keyboard_layout=sideways\n"
        )

        data = self.mod.load_settings()
        self.assertEqual(data["display"], "auto")
        self.assertEqual(data["font_panel"], "6x12")
        self.assertEqual(data["font_hdmi"], "auto")
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
            font_panel="8x16",
            font_hdmi="20x40",
            brightness=55,
            keyboard_layouts="us,ua,de",
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

    def test_layouts_are_normalized_in_canonical_order(self):
        self.assertEqual(self.mod.normalize_layouts("de, us ,de,bogus"), ["us", "de"])
        self.assertEqual(
            self.mod.layout_codes({"keyboard_layouts": "ru,ua"}), ["ua", "ru"]
        )
        # An unknown active layout falls back to the first enabled one.
        self.assertEqual(
            self.mod.active_layout(
                {"keyboard_layouts": "us,de", "keyboard_layout_active": "fr"}
            ),
            "us",
        )

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

    def test_package_metadata_parsing(self):
        text = (
            "Package: tmux\n"
            "Status: install ok installed\n"
            "Section: admin\n"
            "Version: 3.4-1\n"
            "Description: terminal multiplexer\n"
            " tmux lets you switch between programs.\n"
            " .\n"
            " It is scriptable.\n"
            "\n"
            "Package: htop\n"
            "Section: utils\n"
            "Description: interactive process viewer\n"
        )
        stanzas = self.mod.parse_deb822(text)
        self.assertEqual([s["Package"] for s in stanzas], ["tmux", "htop"])
        self.assertEqual(
            self.mod.summary_line(stanzas[0]["Description"]),
            "terminal multiplexer",
        )
        self.assertIn(
            "scriptable", self.mod.long_description(stanzas[0]["Description"])
        )
        self.assertEqual(self.mod.normalize_section("non-free/utils"), "utils")
        self.assertEqual(self.mod.section_label("utils"), "Utilities")

    def test_terminal_package_filter(self):
        terminal = ("/usr/bin/tmux", "/usr/share/man/man1/tmux.1.gz")
        self.assertTrue(self.mod.files_have_program(terminal))
        self.assertFalse(self.mod.files_have_program(("/usr/lib/libfoo.so",)))
        self.assertFalse(
            self.mod.package_looks_gui("admin", "libc6, libtinfo6", terminal)
        )
        self.assertTrue(self.mod.package_looks_gui("utils", "libgtk-3-0", ()))
        self.assertTrue(
            self.mod.package_looks_gui(
                "utils", "", ("/usr/share/applications/foo.desktop",)
            )
        )

    def test_available_package_skips_libraries_and_gui(self):
        stanza = {
            "Package": "htop",
            "Section": "utils",
            "Description": "interactive process viewer",
        }
        self.assertIsNotNone(self.mod.available_package(stanza))
        self.assertIsNone(
            self.mod.available_package(dict(stanza, Package="libfoo", Section="libs"))
        )
        self.assertIsNone(
            self.mod.available_package(dict(stanza, Package="htop-dev"))
        )
        self.assertIsNone(
            self.mod.available_package(
                dict(stanza, Package="galculator", Depends="libgtk-3-0")
            )
        )

    def test_packages_are_grouped_by_category(self):
        installed = [
            {"name": "tmux", "section": "admin", "installed": True},
            {"name": "htop", "section": "utils", "installed": True},
        ]
        groups = self.mod.group_packages(installed)
        self.assertEqual([label for label, _ in groups], ["System", "Utilities"])
        self.assertEqual(groups[0][1][0]["name"], "tmux")
        # Already installed packages are not offered again.
        available = [
            {"name": "tmux", "section": "admin", "installed": False},
            {"name": "nano", "section": "editors", "installed": False},
        ]
        groups = self.mod.group_packages(available, {"tmux"})
        self.assertEqual([label for label, _ in groups], ["Editors"])

    def test_core_packages_are_protected(self):
        optional = {"name": "cowsay", "priority": "optional", "essential": False}
        tmux = {"name": "tmux", "priority": "optional", "essential": False}
        essential = {"name": "bash", "priority": "required", "essential": True}
        self.assertFalse(self.mod.package_is_protected(optional))
        self.assertTrue(self.mod.package_is_protected(tmux))
        self.assertTrue(self.mod.package_is_protected(essential))


if __name__ == "__main__":
    unittest.main()
