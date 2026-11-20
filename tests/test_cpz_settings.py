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
    "show_layout",
    "display",
    "font_family",
    "font_size_panel",
    "font_size_hdmi",
    "brightness",
    "screen_timeout",
    "mouse",
    "mouse_speed",
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
        self.assertEqual(data["font_family"], "terminus")
        self.assertEqual(data["font_size_panel"], 12)
        self.assertEqual(data["font_size_hdmi"], 16)
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
            "font_family=bogus\n"
            "font_size=999\n"
            "history_limit=7\n"
            "mode_keys=weird\n"
            "screen_timeout=7\n"
            "status_interval=3\n"
            "brightness=-5\n"
            "keyboard_layout=sideways\n"
        )

        data = self.mod.load_settings()
        self.assertEqual(data["display"], "auto")
        self.assertEqual(data["font_family"], "terminus")
        # Values are clamped, not rejected.
        self.assertEqual(data["font_size_panel"], 32)
        self.assertEqual(data["font_size_hdmi"], 32)
        self.assertEqual(data["history_limit"], 2000)
        self.assertEqual(data["mode_keys"], "vi")
        self.assertEqual(data["screen_timeout"], 0)
        self.assertEqual(data["status_interval"], 5)
        self.assertEqual(data["brightness"], 0)
        self.assertEqual(data["keyboard_layout"], "auto")

    def test_unknown_keys_are_ignored(self):
        self.write_user("unknown_key=42\ntheme=cpz-homebrew\n")
        data = self.mod.load_settings()
        self.assertEqual(data["theme"], "cpz-homebrew")
        self.assertNotIn("unknown_key", data)

    def test_mouse_speed_row_maps_tenths_to_libinput_range(self):
        data = dict(self.mod.DEFAULTS)
        items = {
            item["label"]: item
            for item in self.mod.page_items("keyboard", data, None)
        }
        item = items["Mouse Speed"]
        self.assertEqual(item["kind"], "scale")
        self.assertEqual(item["key"], "mouse_speed")
        self.assertEqual(item["values"], tuple(range(-10, 11)))
        self.assertEqual(item["labels"][-10], "-1.0")
        self.assertEqual(item["labels"][-3], "-0.3")
        self.assertEqual(item["labels"][0], "0.0")
        self.assertEqual(item["labels"][4], "+0.4")
        self.assertEqual(item["labels"][10], "+1.0")

        self.write_user("mouse_speed=7\n")
        self.assertEqual(self.mod.load_settings()["mouse_speed"], 7)
        self.write_user("mouse_speed=99\n")
        self.assertEqual(self.mod.load_settings()["mouse_speed"], 10)

    def test_wifi_action_opens_the_shared_radio_manager(self):
        with mock.patch.object(
            self.mod, "radio_manager_screen", return_value=None
        ) as manager:
            self.mod.wifi_action(None, {})
        manager.assert_called_once_with(None, "wifi")

    def test_bt_action_opens_the_shared_radio_manager(self):
        with mock.patch.object(
            self.mod, "radio_manager_screen", return_value=None
        ) as manager:
            self.mod.bt_action(None, {})
        manager.assert_called_once_with(None, "bluetooth")

    def test_wifi_networks_keep_one_row_per_ssid(self):
        output = (
            "*:82:WPA2:Home\n"
            ":45:WPA2:Home\n"
            ":67:--:Cafe\\:Guest\n"
            ":30:: \n"
        )
        networks = self.mod.parse_wifi_networks(output)
        self.assertEqual(
            [entry["ssid"] for entry in networks], ["Home", "Cafe:Guest"]
        )
        self.assertTrue(networks[0]["active"])
        self.assertEqual(networks[0]["signal"], 82)
        self.assertEqual(networks[1]["security"], "--")
        self.assertEqual(networks[1]["signal"], 67)

    def test_wifi_networks_sort_active_then_signal(self):
        output = (
            ":20:WPA2:Far\n"
            ":90:WPA2:Strong\n"
            "*:40:WPA2:Current\n"
        )
        networks = self.mod.parse_wifi_networks(output)
        self.assertEqual(
            [entry["ssid"] for entry in networks],
            ["Current", "Strong", "Far"],
        )

    def test_bluetooth_info_mirrors_the_wifi_status_shape(self):
        with mock.patch.object(
            self.mod.shutil, "which", return_value="/usr/bin/bluetoothctl"
        ):
            self.mod.bt_adapter = lambda: {
                "name": "hci0",
                "mac": "AA:BB",
                "powered": False,
                "error": "",
            }
            self.assertEqual(self.mod.bluetooth_info(), "Off")

            self.mod.bt_adapter = lambda: {
                "name": "hci0",
                "mac": "AA:BB",
                "powered": True,
                "error": "",
            }
            self.mod.bt_devices = lambda: [
                {
                    "mac": "11:22",
                    "name": "Headphones",
                    "paired": True,
                    "connected": True,
                    "trusted": True,
                }
            ]
            self.assertEqual(
                self.mod.bluetooth_info(), "Headphones - connected"
            )

    def test_ssh_enable_generates_keys_and_disables_socket_activation(self):
        with mock.patch.object(
            self.mod, "ssh_status", return_value="inactive,disabled"
        ), mock.patch.object(
            self.mod, "run_privileged", return_value=0
        ) as run:
            self.assertIsNone(self.mod.ssh_toggle(None, {}))
        commands = [call.args[1] for call in run.call_args_list]
        self.assertIn(["ssh-keygen", "-A"], commands)
        self.assertIn(["systemctl", "disable", "--now", "ssh.socket"], commands)
        self.assertEqual(
            commands[-1], ["systemctl", "enable", "--now", "ssh"]
        )

    def test_ssh_disable_turns_off_socket_activation(self):
        with mock.patch.object(
            self.mod, "ssh_status", return_value="active,enabled"
        ), mock.patch.object(
            self.mod, "run_privileged", return_value=0
        ) as run:
            self.assertIsNone(self.mod.ssh_toggle(None, {}))
        commands = [call.args[1] for call in run.call_args_list]
        self.assertIn(["systemctl", "disable", "--now", "ssh.socket"], commands)
        self.assertEqual(
            commands[-1], ["systemctl", "disable", "--now", "ssh"]
        )

    def test_wifi_connect_uses_a_saved_profile(self):
        self.mod.wifi_saved_networks = lambda: {"Home"}
        network = {
            "ssid": "Home",
            "signal": 80,
            "security": "WPA2",
            "active": False,
        }
        with mock.patch.object(
            self.mod, "nm_run", return_value=(0, "", "")
        ) as run:
            self.assertEqual(self.mod.wifi_connect(None, network), "")
        run.assert_called_once_with(
            ["nmcli", "connection", "up", "id", "Home"], timeout=45
        )

    def test_wifi_connect_asks_for_a_new_passphrase(self):
        self.mod.wifi_saved_networks = lambda: set()
        network = {
            "ssid": "Cafe",
            "signal": 50,
            "security": "WPA2",
            "active": False,
        }
        with mock.patch.object(
            self.mod, "text_input", return_value="secret"
        ), mock.patch.object(
            self.mod, "nm_run", return_value=(0, "", "")
        ) as run:
            self.assertEqual(self.mod.wifi_connect(None, network), "")
        self.assertEqual(
            run.call_args.args[0],
            [
                "nmcli",
                "device",
                "wifi",
                "connect",
                "Cafe",
                "password",
                "secret",
            ],
        )

    def test_bluetooth_pair_uses_the_non_interactive_agent(self):
        with mock.patch.object(
            self.mod, "bt_run", return_value=(0, "", "")
        ) as run:
            self.assertEqual(self.mod.bt_pair_command("11:22"), "")
        run.assert_called_once_with(
            [
                "bluetoothctl",
                "-a",
                "NoInputNoOutput",
                "pair",
                "11:22",
            ],
            timeout=40,
        )

    def test_save_and_load_round_trip(self):
        data = self.mod.load_settings()
        data.update(
            theme="cpz-homebrew",
            show_clock=0,
            date_format="iso",
            display="hdmi",
            font_family="hack",
            font_size_panel=18,
            font_size_hdmi=24,
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
        # 6x12/8x16 were the old panel presets; a single font_size seeds both
        # outputs, and an explicit per-output key wins.
        self.write_user("font_panel=8x16\n")
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 16)
        self.assertEqual(data["font_size_hdmi"], 16)

        self.write_user("font_hdmi=8x16\n")
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 12)
        self.assertEqual(data["font_size_hdmi"], 16)

        self.write_user("font_panel=8x16\nfont_size=22\n")
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 16)
        self.assertEqual(data["font_size_hdmi"], 22)

        self.write_user("font_size=22\n")
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 22)
        self.assertEqual(data["font_size_hdmi"], 22)

    def test_user_legacy_font_beats_system_defaults(self):
        # An older image ships a legacy font_size and a newer one ships the
        # per-output keys; a user file from either build must win.
        self.system.write_text("font_size=12\n", encoding="utf-8")
        self.write_user("font_size=32\n")
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 32)
        self.assertEqual(data["font_size_hdmi"], 32)

        self.system.write_text(
            "font_size_panel=12\nfont_size_hdmi=16\n", encoding="utf-8"
        )
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 32)
        self.assertEqual(data["font_size_hdmi"], 32)

        # An explicit per-output key in the user file still wins.
        self.write_user("font_size=32\nfont_size_hdmi=24\n")
        data = self.mod.load_settings()
        self.assertEqual(data["font_size_panel"], 32)
        self.assertEqual(data["font_size_hdmi"], 24)

    def test_font_key_follows_the_active_output(self):
        import os
        import tempfile
        from pathlib import Path

        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / "output.state"
            previous = os.environ.get("CPZ_OUTPUT_STATE")
            os.environ["CPZ_OUTPUT_STATE"] = str(state)
            try:
                state.write_text("target=panel\n", encoding="utf-8")
                self.assertEqual(self.mod.font_key(), "font_size_panel")
                state.write_text("target=hdmi\n", encoding="utf-8")
                self.assertEqual(self.mod.font_key(), "font_size_hdmi")
                state.unlink()
                self.assertEqual(self.mod.font_key(), "font_size_panel")
            finally:
                if previous is None:
                    os.environ.pop("CPZ_OUTPUT_STATE", None)
                else:
                    os.environ["CPZ_OUTPUT_STATE"] = previous

    def test_font_size_choices_cover_the_key_bindings(self):
        self.assertEqual(self.mod.FONT_SIZE_MIN, 12)
        self.assertEqual(self.mod.FONT_SIZE_MAX, 32)
        self.assertEqual(self.mod.FONT_SIZES, (12, 14, 16, 18, 20, 22, 24, 28, 32))
        self.assertIn(12, self.mod.FONT_SIZES)
        self.assertEqual(self.mod.DEFAULTS["font_size_panel"], 12)
        self.assertEqual(self.mod.DEFAULTS["font_size_hdmi"], 16)
        self.assertIn(16, self.mod.FONT_SIZES)
        self.assertNotIn(10, self.mod.FONT_SIZES)
        self.assertEqual(self.mod.nearest_font_size(10), 12)
        self.assertEqual(self.mod.nearest_font_size(64), 32)
        self.assertEqual(self.mod.FONT_SIZE_LABELS[14], "14px")

    def test_display_page_offers_the_installed_font_families(self):
        data = dict(self.mod.DEFAULTS)
        items = {
            item["label"]: item
            for item in self.mod.page_items("display", data, None)
        }
        item = items["Font"]
        self.assertEqual(item["kind"], "picker")
        self.assertEqual(item["key"], "font_family")
        self.assertEqual(tuple(item["values"]), self.mod.FONT_FAMILIES)
        self.assertEqual(set(item["labels"]), set(item["values"]))
        self.assertEqual(item["labels"]["jetbrains"], "JetBrains Mono")
        self.assertEqual(data["font_family"], "terminus")

    def test_display_page_offers_the_screen_timeout(self):
        data = dict(self.mod.DEFAULTS)
        items = {
            item["label"]: item
            for item in self.mod.page_items("display", data, None)
        }
        item = items["Screen Timeout"]
        self.assertEqual(item["kind"], "picker")
        self.assertEqual(item["key"], "screen_timeout")
        self.assertEqual(tuple(item["values"]), self.mod.SCREEN_TIMEOUTS)
        self.assertIn(1, item["values"])
        self.assertEqual(item["labels"][1], "1 min")

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

    def test_every_named_set_is_a_picker_and_never_a_blind_cycle(self):
        data = dict(self.mod.DEFAULTS)
        data.update(show_clock=1, show_date=1)
        data["keyboard_layouts"] = "us,de"
        for page in self.mod.PAGE_TITLES:
            for item in self.mod.page_items(page, data, None):
                if "values" not in item:
                    continue
                self.assertIn(
                    item["kind"],
                    ("picker", "scale"),
                    f"{page}: {item['label']}",
                )
                if item["kind"] == "picker":
                    self.assertTrue(
                        item.get("key") or item.get("set"),
                        f"{page}: {item['label']} has no way to apply a choice",
                    )

    def test_binary_settings_use_the_toggle_pattern(self):
        data = dict(self.mod.DEFAULTS)
        datetime_items = {
            item["label"]: item
            for item in self.mod.page_items("datetime", data, None)
        }
        self.assertEqual(datetime_items["Clock Sync"]["kind"], "toggle")
        security_items = {
            item["label"]: item
            for item in self.mod.page_items("security", data, None)
        }
        self.assertEqual(security_items["SSH"]["kind"], "toggle")
        sound_items = {
            item["label"]: item
            for item in self.mod.page_items("sound", data, None)
        }
        self.assertEqual(sound_items["Output Mute"]["kind"], "toggle")

    def test_keyboard_and_audio_device_choices_open_pickers(self):
        data = dict(self.mod.DEFAULTS)
        data["keyboard_layouts"] = "us,de"
        data["keyboard_layout_active"] = "de"
        keyboard = {
            item["label"]: item
            for item in self.mod.page_items("keyboard", data, None)
        }
        self.assertEqual(keyboard["Keyboard Mapping"]["kind"], "picker")
        self.assertEqual(
            tuple(keyboard["Keyboard Mapping"]["values"]),
            ("auto", "cpz", "standard"),
        )
        self.assertEqual(keyboard["Active Layout"]["kind"], "picker")

        sound = {
            item["label"]: item
            for item in self.mod.page_items("sound", data, None)
        }
        self.assertEqual(sound["Output Volume"]["kind"], "scale")
        self.assertTrue(callable(sound["Output Volume"]["set"]))
        self.assertEqual(sound["Output Device"]["kind"], "picker")
        self.assertTrue(callable(sound["Output Device"]["set"]))

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
        keys = {item.get("key") for item in items}
        self.assertIn("show_conn", keys)
        for key in ("show_eth", "show_wifi", "show_bt"):
            self.assertNotIn(key, keys)

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
        self.mod.trove_apt_names = lambda: {"tmux", "lazygit", "github-cli"}

        payload = self.mod.list_tools_payload()
        self.assertEqual(payload["schema"], 1)
        tools = {tool["slug"]: tool for tool in payload["tools"]}
        self.assertEqual(tools["tmux"]["command"], "tmux")
        self.assertTrue(tools["tmux"]["installed"])
        self.assertFalse(tools["tmux"]["managed"])
        self.assertEqual(tools["tmux"]["apt"], "tmux")
        self.assertTrue(tools["tmux"]["available"])
        self.assertEqual(tools["lazygit"]["command"], "")
        self.assertFalse(tools["lazygit"]["installed"])
        self.assertFalse(tools["lazygit"]["managed"])
        self.assertTrue(tools["lazygit"]["available"])
        self.assertEqual(tools["github-cli"]["command"], "gh")
        self.assertTrue(tools["github-cli"]["installed"])
        self.assertTrue(tools["github-cli"]["managed"])

    def test_apt_search_finds_plain_packages_and_skips_libraries(self):
        self.mod.apt_metadata_many = lambda packages: {
            package: {"summary": f"summary {package}"}
            for package in packages
        }
        names = {
            "nano",
            "nano-tiny",
            "libnano6",
            "nano-doc",
            "nano-dev",
            "tmux",
        }
        tools = self.mod.apt_search_tools("nano", names, {"tmux"})
        self.assertEqual(
            [tool["slug"] for tool in tools],
            ["nano", "nano-tiny"],
        )
        self.assertEqual(tools[0]["summary"], "summary nano")
        self.assertEqual(tools[0]["apt"]["package"], "nano")
        self.assertEqual(tools[0]["apt"]["command"], "apt install nano")
        self.assertEqual(self.mod.apt_search_tools("n", names), [])
        self.assertEqual(
            self.mod.apt_search_tools("tmux", names, {"tmux"}), []
        )

    def test_browse_starts_with_index_and_appends_apt_only_on_search(self):
        catalog = [
            {
                "slug": "tmux",
                "name": "tmux",
                "apt": {"package": "tmux", "command": "apt install tmux"},
            }
        ]
        apt_extra = [{"slug": "nano", "name": "nano"}]
        cache: dict = {}
        with mock.patch.object(
            self.mod, "filter_trove_tools", return_value=catalog
        ) as filtered, mock.patch.object(
            self.mod, "apt_search_tools", return_value=apt_extra
        ) as apt_search:
            default = self.mod.browse_trove_tools(
                [], {"nano"}, ["nano"], "", "", "", True, cache
            )
            self.assertEqual([tool["slug"] for tool in default], ["tmux"])
            apt_search.assert_not_called()
            filtered.assert_called_with([], "", "", "", {"nano"})

            found = self.mod.browse_trove_tools(
                [], {"nano"}, ["nano"], "nano", "", "", True, cache
            )
            self.assertEqual(
                [tool["slug"] for tool in found], ["tmux", "nano"]
            )
            apt_search.assert_called_once()

    def test_gui_signals_use_section_dependencies_and_launchers(self):
        self.mod.apt_metadata = lambda _package: {
            "section": "gnome",
            "depends": "libc6, libgtk-3-0",
        }
        self.mod.package_desktop_files = lambda _package: [
            "/usr/share/applications/example.desktop"
        ]
        signals = self.mod.trove_gui_signals(
            {"slug": "example", "categories": []},
            {"package": "example", "status": "installed"},
        )
        text = "\n".join(signals)
        self.assertIn("apt section: gnome", text)
        self.assertIn("depends on libgtk", text)
        self.assertIn("desktop launcher", text)

    def test_trove_details_show_the_desktop_warning(self):
        tool = {
            "slug": "example",
            "name": "example",
            "summary": "an example",
            "description": "",
            "categories": [],
            "platforms": ["linux"],
            "install": {},
            "apt": {"package": "example", "command": "apt install example"},
        }
        lines = self.mod.trove_details_lines(
            tool,
            {"package": "example", "status": "available", "version": ""},
            None,
            60,
            gui_signals=["apt section: gnome"],
        )
        text = "\n".join(lines)
        self.assertIn("may be a desktop app", text)
        self.assertIn("apt section: gnome", text)

    def test_find_trove_tool_falls_back_to_managed_apt_apps(self):
        self.mod.load_trove_index = lambda: {"tools": []}
        self.mod.read_trove_apps = lambda: {
            "nano": {
                "slug": "nano",
                "name": "nano",
                "package": "nano",
            }
        }
        tool = self.mod.find_trove_tool("nano")
        self.assertIsNotNone(tool)
        self.assertEqual(tool["slug"], "nano")
        self.assertEqual(tool["apt"]["package"], "nano")
        self.assertEqual(tool["_record"]["package"], "nano")
        self.assertIsNone(self.mod.find_trove_tool("missing"))

    def test_tool_payload_includes_managed_apps_without_catalog_rows(self):
        self.mod.load_trove_index = lambda: {"tools": []}
        self.mod.read_trove_apps = lambda: {
            "nano": {
                "slug": "nano",
                "name": "nano",
                "package": "nano",
            }
        }
        self.mod.executable_names = lambda: {"nano"}
        self.mod.managed_trove_command = lambda _record, _available: "nano"
        self.mod.trove_apt_names = lambda: {"nano"}
        payload = self.mod.list_tools_payload()
        tools = {tool["slug"]: tool for tool in payload["tools"]}
        self.assertEqual(tools["nano"]["command"], "nano")
        self.assertTrue(tools["nano"]["installed"])
        self.assertTrue(tools["nano"]["managed"])
        self.assertEqual(tools["nano"]["apt"], "nano")

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

    def test_trove_install_tool_records_the_app(self):
        tool = {
            "slug": "btop",
            "name": "btop",
            "apt": {"command": "apt install btop", "package": "btop"},
        }
        self.mod.resolve_trove_apt = lambda _tool, _names: {
            "package": "btop",
            "status": "available",
            "version": "",
        }
        self.mod.trove_gui_signals = lambda _tool, _apt: []
        self.mod.confirm = lambda *_args, **_kwargs: True
        self.mod.run_privileged = lambda *_args, **_kwargs: 0
        self.mod.apt_status = lambda package: {
            "package": package,
            "status": "installed",
            "version": "1.4.0",
        }
        self.mod.trove_install_tool(mock.Mock(), tool, {"btop"})
        apps = self.mod.read_trove_apps()
        self.assertIn("btop", apps)
        self.assertEqual(apps["btop"]["package"], "btop")
        self.assertEqual(apps["btop"]["version"], "1.4.0")

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

    def test_installed_tab_lists_only_manager_records(self):
        """apt/system packages must not leak into the Installed tab."""
        index = {
            "tools": [
                {"slug": "tmux", "name": "tmux", "apt": {"package": "tmux"}},
                {"slug": "btop", "name": "btop", "apt": {"package": "btop"}},
            ]
        }
        managed = {
            "btop": {
                "slug": "btop",
                "name": "btop",
                "package": "btop",
                "version": "1.4.0",
                "installed_at": "2026-11-19T00:00:00",
                "install_command": "apt install btop",
                "uninstall_command": "apt-get purge btop",
            }
        }
        shown = self.mod.trove_installed_tools(index, managed)
        self.assertEqual([tool["slug"] for tool in shown], ["btop"])
        # tmux is in the catalog and may be installed system-wide, but it has
        # no manager record, so it stays out of Installed.
        self.assertNotIn("tmux", [tool["slug"] for tool in shown])

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


class RadioManager(unittest.TestCase):
    """Drive the shared borderless manager with a fake curses screen."""

    class FakeScreen:
        def __init__(self, keys, height=14, width=53):
            self.keys = list(keys)
            self.height = height
            self.width = width
            self.rows = {}

        def getmaxyx(self):
            return self.height, self.width

        def erase(self):
            self.rows = {}

        def refresh(self):
            pass

        def timeout(self, _milliseconds):
            pass

        def addstr(self, y, x, text, attr=0):
            self.rows.setdefault(y, []).append((x, text, attr))

        def getch(self):
            return self.keys.pop(0) if self.keys else -1

        def text(self, row):
            pieces = sorted(self.rows.get(row, []), key=lambda item: item[0])
            return "".join(piece[1] for piece in pieces)

    def setUp(self):
        self.mod = load_settings_module()

    def wifi(self, keys):
        screen = self.FakeScreen(keys)
        networks = [
            {
                "ssid": "Home",
                "signal": 82,
                "security": "WPA2",
                "active": True,
            },
            {
                "ssid": "Cafe",
                "signal": 40,
                "security": "--",
                "active": False,
            },
        ]
        with mock.patch.multiple(
            self.mod,
            wifi_prepare=lambda _screen: "",
            wifi_networks=lambda scan=False: (networks, ""),
            wifi_saved_networks=lambda: {"Home"},
            wifi_summary=lambda: "Home",
            wifi_interface=lambda: "wlan0",
            wifi_radio_enabled=lambda: True,
            hint_attr=lambda: 0,
        ):
            self.mod.radio_manager_screen(screen, "wifi")
        return screen

    def test_wifi_screen_has_no_border_and_one_combined_footer(self):
        screen = self.wifi([ord("q")])
        self.assertIn("Wi-Fi", screen.text(0))
        self.assertIn("wlan0", screen.text(0))
        self.assertIn("[Enter] Disconnect", screen.text(1))
        self.assertIn("[o] Turn off", screen.text(1))
        self.assertIn("Home", screen.text(2))
        self.assertIn("82%", screen.text(2))
        self.assertIn("Cafe", screen.text(3))
        self.assertIn("s scan", screen.text(13))
        self.assertIn("q back", screen.text(13))
        self.assertIn("Home", screen.text(13))

    def test_wifi_scan_status_replaces_the_summary_in_the_footer(self):
        screen = self.FakeScreen([ord("s"), ord("q")])
        networks = [
            {
                "ssid": "Home",
                "signal": 82,
                "security": "WPA2",
                "active": True,
            }
        ]
        with mock.patch.multiple(
            self.mod,
            wifi_prepare=lambda _screen: "",
            wifi_networks=lambda scan=False: (networks, ""),
            wifi_saved_networks=lambda: set(),
            wifi_summary=lambda: "Home",
            wifi_interface=lambda: "wlan0",
            wifi_radio_enabled=lambda: True,
            hint_attr=lambda: 0,
        ):
            self.mod.radio_manager_screen(screen, "wifi")
        self.assertIn("Scan complete", screen.text(13))
        self.assertIn("s scan", screen.text(13))

    def test_bluetooth_screen_matches_the_wifi_layout(self):
        screen = self.FakeScreen([ord("q")])
        devices = [
            {
                "mac": "11:22",
                "name": "Headphones",
                "paired": True,
                "connected": True,
                "trusted": True,
            },
            {
                "mac": "33:44",
                "name": "Keyboard",
                "paired": False,
                "connected": False,
                "trusted": False,
            },
        ]
        with mock.patch.multiple(
            self.mod,
            bt_set_radio=lambda _screen, _enabled: "",
            bt_devices=lambda: devices,
            bt_adapter=lambda: {
                "name": "hci0",
                "mac": "AA:BB",
                "powered": True,
                "error": "",
            },
            bluetooth_summary=lambda: "Headphones",
            hint_attr=lambda: 0,
        ):
            self.mod.radio_manager_screen(screen, "bluetooth")
        self.assertIn("Bluetooth", screen.text(0))
        self.assertIn("hci0", screen.text(0))
        self.assertIn("Headphones", screen.text(2))
        self.assertIn("connected", screen.text(2))
        self.assertIn("Keyboard", screen.text(3))
        self.assertIn("new", screen.text(3))
        self.assertIn("[Enter] Disconnect", screen.text(1))
        self.assertIn("[o] Turn off", screen.text(1))
        self.assertIn("s scan", screen.text(13))
        self.assertIn("d remove", screen.text(13))
        self.assertIn("q back", screen.text(13))

    def test_bluetooth_scan_status_and_cleanup(self):
        class Process:
            terminated = False

            def poll(self):
                return None

            def terminate(self):
                self.terminated = True

        process = Process()
        screen = self.FakeScreen([ord("s"), -1, ord("q")])
        with mock.patch.multiple(
            self.mod,
            bt_set_radio=lambda _screen, _enabled: "",
            bt_devices=lambda: [],
            bt_adapter=lambda: {
                "name": "hci0",
                "mac": "AA:BB",
                "powered": True,
                "error": "",
            },
            bluetooth_summary=lambda: "On",
            bt_start_scan=lambda: process,
            hint_attr=lambda: 0,
        ):
            self.mod.radio_manager_screen(screen, "bluetooth")
        self.assertIn("Scanning...", screen.text(13))
        self.assertTrue(process.terminated)


if __name__ == "__main__":
    unittest.main()
