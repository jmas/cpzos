"""Unit tests for the pure helpers in the CPZ settings TUI.

The TUI itself needs curses and a terminal; everything tested here is the
policy that decides what gets written to ~/.config/cpz/settings.conf.
"""

from __future__ import annotations

import contextlib
import curses
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
        self.mod.HUB_INDEX_SYSTEM = str(
            root / "usr" / "share" / "cpz" / "hub.json"
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

    def test_hub_index_loading_and_filters(self):
        cache = Path(self.mod.hub_cache_path())
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "generated_at": "2026-11-20T00:00:00+00:00",
                    "apps": [
                        {
                            "id": "btop",
                            "name": "btop",
                            "summary": "resource monitor",
                            "kind": "apt",
                            "package": "btop",
                            "categories": ["monitor", "tui"],
                        },
                        {
                            "id": "wifitui",
                            "name": "wifitui",
                            "summary": "Wi-Fi TUI",
                            "kind": "deb",
                            "package": "cpz-app-wifitui",
                            "version": "0.13.0",
                            "categories": ["network"],
                            "deb": {
                                "url": "https://example.com/wifitui.deb",
                                "sha256": "a" * 64,
                            },
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )

        loaded = self.mod.load_hub_index()
        self.assertEqual(loaded["count"] if "count" in loaded else len(loaded["apps"]), 2)
        self.assertEqual([app["id"] for app in loaded["apps"]], ["btop", "wifitui"])
        self.assertEqual(loaded["apps"][1]["kind"], "deb")
        self.assertEqual(
            [app["id"] for app in self.mod.filter_hub_apps(loaded["apps"], "wifi")],
            ["wifitui"],
        )
        self.assertEqual(
            [app["id"] for app in self.mod.filter_hub_apps(loaded["apps"], "monitor")],
            ["btop"],
        )

    def test_hub_index_drops_invalid_deb_entries(self):
        app = self.mod.normalize_hub_app(
            {
                "id": "broken",
                "name": "Broken",
                "kind": "deb",
                "package": "cpz-app-broken",
                "version": "1.0",
                "deb": {"url": "https://example.com/broken.deb", "sha256": "x"},
            }
        )
        self.assertIsNone(app)

    def test_hub_tool_list_for_search(self):
        apps = [
            {
                "id": "btop",
                "name": "btop",
                "summary": "resource monitor",
                "kind": "apt",
                "package": "btop",
                "categories": ["monitor"],
            },
            {
                "id": "wifitui",
                "name": "wifitui",
                "summary": "Wi-Fi TUI",
                "kind": "deb",
                "package": "cpz-app-wifitui",
                "version": "0.13.0",
                "categories": ["network"],
            },
        ]
        self.mod.load_hub_index = lambda: {"schema": 1, "apps": apps}
        self.mod.read_hub_apps = lambda: {
            "wifitui": {
                "slug": "wifitui",
                "name": "wifitui",
                "kind": "deb",
                "package": "cpz-app-wifitui",
                "version": "0.13.0",
            }
        }
        self.mod.dpkg_installed = lambda: {"btop": "1.4.0"}
        self.mod.executable_names = lambda: {"btop", "wifitui"}

        payload = self.mod.list_tools_payload()
        tools = {tool["slug"]: tool for tool in payload["tools"]}
        self.assertEqual(tools["btop"]["command"], "btop")
        self.assertTrue(tools["btop"]["installed"])
        self.assertFalse(tools["btop"]["managed"])
        self.assertEqual(tools["btop"]["package"], "btop")
        self.assertTrue(tools["wifitui"]["installed"])
        self.assertTrue(tools["wifitui"]["managed"])
        self.assertEqual(tools["wifitui"]["kind"], "deb")

    def test_hub_tool_list_includes_removed_catalog_apps(self):
        self.mod.load_hub_index = lambda: {"schema": 1, "apps": []}
        self.mod.read_hub_apps = lambda: {
            "oldapp": {
                "slug": "oldapp",
                "name": "Old App",
                "kind": "apt",
                "package": "oldapp",
                "version": "1.0",
            }
        }
        self.mod.dpkg_installed = lambda: {"oldapp": "1.0"}
        self.mod.executable_names = lambda: set()
        payload = self.mod.list_tools_payload()
        self.assertEqual(payload["tools"][0]["slug"], "oldapp")
        self.assertTrue(payload["tools"][0]["installed"])

    def test_cli_install_tool_records_the_app(self):
        self.mod.load_hub_index = lambda: {
            "schema": 1,
            "apps": [
                {
                    "id": "btop",
                    "name": "btop",
                    "summary": "",
                    "kind": "apt",
                    "package": "btop",
                    "categories": [],
                }
            ],
        }
        self.mod.dpkg_installed = mock.Mock(
            side_effect=[{}, {"btop": "1.4"}]
        )
        self.mod.apt_lists_present = lambda: True
        with mock.patch.object(
            self.mod.subprocess, "call", return_value=0
        ) as run:
            with mock.patch("builtins.print"):
                self.assertEqual(self.mod.cli_install_tool("btop"), 0)
        run.assert_called_once()
        command = run.call_args.args[0]
        self.assertIn("apt-get", command)
        self.assertIn("btop", command)
        apps = self.mod.read_hub_apps()
        self.assertEqual(apps["btop"]["package"], "btop")
        self.assertEqual(apps["btop"]["version"], "1.4")

    def test_cli_install_tool_rejects_unknown_ids(self):
        self.mod.load_hub_index = lambda: {"schema": 1, "apps": []}
        self.mod.read_hub_apps = lambda: {}
        with mock.patch("builtins.print"):
            self.assertEqual(self.mod.cli_install_tool("missing"), 2)

    def test_hub_install_tool_records_the_app(self):
        app = {
            "id": "btop",
            "name": "btop",
            "summary": "",
            "kind": "apt",
            "package": "btop",
            "categories": [],
        }
        self.mod.read_hub_apps = lambda: {}
        self.mod.dpkg_installed = mock.Mock(
            side_effect=[{}, {"btop": "1.4.0"}]
        )
        self.mod.apt_lists_present = lambda: True
        self.mod.confirm = lambda *args, **kwargs: True
        self.mod.run_privileged = mock.Mock(return_value=0)
        message = self.mod.hub_install_tool(mock.Mock(), app)
        self.assertIn("Installed btop", message)
        command = self.mod.run_privileged.call_args.args[1]
        self.assertIn("apt-get", command)
        self.assertIn("btop", command)

    def test_hub_deb_install_uses_the_verified_file(self):
        app = {
            "id": "wifitui",
            "name": "wifitui",
            "summary": "",
            "kind": "deb",
            "package": "cpz-app-wifitui",
            "version": "0.13.0",
            "categories": [],
            "deb": {"url": "https://example.com/wifitui.deb", "sha256": "a" * 64},
        }
        self.mod.read_hub_apps = lambda: {}
        self.mod.dpkg_installed = mock.Mock(
            side_effect=[{}, {"cpz-app-wifitui": "0.13.0"}]
        )
        self.mod.fetch_hub_deb = lambda _app: ("/tmp/wifitui.deb", "")
        self.mod.apt_lists_present = lambda: True
        self.mod.draw_loading = lambda *args: None
        self.mod.confirm = lambda *args, **kwargs: True
        self.mod.run_privileged = mock.Mock(return_value=0)
        message = self.mod.hub_install_tool(mock.Mock(), app)
        self.assertIn("Installed wifitui", message)
        command = self.mod.run_privileged.call_args.args[1]
        self.assertIn("/tmp/wifitui.deb", command)

    def test_hub_deb_download_verifies_the_checksum(self):
        payload = b"fake deb payload"
        digest = __import__("hashlib").sha256(payload).hexdigest()
        app = {
            "id": "tool",
            "name": "Tool",
            "kind": "deb",
            "package": "cpz-app-tool",
            "version": "1.0",
            "deb": {
                "url": "https://example.com/tool.deb",
                "sha256": digest,
            },
        }

        class Response:
            def __enter__(self):
                return self

            def __exit__(self, *args):
                return False

            def read(self, _limit):
                return payload

        with mock.patch.object(
            self.mod.urllib.request, "urlopen", return_value=Response()
        ):
            path, error = self.mod.fetch_hub_deb(app)
        self.assertEqual(error, "")
        self.assertEqual(self.mod.file_sha256(path), digest)

        app["deb"]["sha256"] = "0" * 64
        with mock.patch.object(
            self.mod.urllib.request, "urlopen", return_value=Response()
        ):
            path, error = self.mod.fetch_hub_deb(app)
        self.assertEqual(path, "")
        self.assertEqual(error, "checksum mismatch")

    def test_hub_details_show_status_and_commands(self):
        app = {
            "id": "btop",
            "name": "btop",
            "summary": "resource monitor",
            "kind": "apt",
            "package": "btop",
            "categories": ["monitor"],
            "license": "Apache-2.0",
        }
        available = self.mod.hub_details_lines(app, None, {}, 60)
        self.assertIn("Install: apt install btop", "\n".join(available))
        system = self.mod.hub_details_lines(app, None, {"btop": "1.0"}, 60)
        self.assertIn(
            "Installed outside the manager; not tracked here.",
            "\n".join(system),
        )
        record = {
            "slug": "btop",
            "name": "btop",
            "package": "btop",
            "version": "1.0",
        }
        managed = self.mod.hub_details_lines(app, record, {"btop": "1.0"}, 60)
        self.assertIn("Remove: apt-get purge btop", "\n".join(managed))

    def test_hub_state_round_trip(self):
        apps = {
            "btop": {
                "slug": "btop",
                "name": "btop",
                "kind": "apt",
                "package": "btop",
                "version": "1.4.0",
                "installed_at": "2026-11-20T00:00:00",
                "install_command": "apt install btop",
                "uninstall_command": "apt-get purge btop",
            }
        }
        self.mod.write_hub_apps(apps)
        self.assertEqual(self.mod.read_hub_apps(), apps)
        path = Path(self.mod.hub_state_path())
        self.assertTrue(path.is_file())
        self.assertEqual(json.loads(path.read_text())["schema"], 1)

    def test_legacy_trove_state_is_migrated_to_hub_scope(self):
        self.mod.load_hub_index = lambda: {
            "schema": 1,
            "apps": [
                {
                    "id": "btop",
                    "name": "btop",
                    "kind": "apt",
                    "package": "btop",
                    "categories": [],
                }
            ],
        }
        legacy = Path(self.mod.legacy_hub_state_path())
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.write_text(
            json.dumps(
                {
                    "version": 1,
                    "apps": [
                        {
                            "slug": "btop",
                            "name": "btop",
                            "package": "btop",
                            "version": "1.4.0",
                        },
                        {
                            "slug": "outsider",
                            "name": "Outside",
                            "package": "outsider",
                            "version": "1.0",
                        },
                    ],
                }
            ),
            encoding="utf-8",
        )
        apps = self.mod.read_hub_apps()
        self.assertEqual(set(apps), {"btop"})
        self.assertTrue(Path(self.mod.hub_state_path()).is_file())

    def test_hub_uninstall_removes_the_record(self):
        record = {
            "slug": "btop",
            "name": "btop",
            "kind": "apt",
            "package": "btop",
            "version": "1.4.0",
        }
        self.mod.read_hub_apps = mock.Mock(
            side_effect=[{"btop": record}, {"btop": record}]
        )
        self.mod.write_hub_apps = mock.Mock()
        self.mod.dpkg_installed = lambda: {"btop": "1.4.0"}
        self.mod.simulate_removal = lambda _package: ["btop"]
        self.mod.confirm = lambda *args, **kwargs: True
        self.mod.run_privileged = mock.Mock(return_value=0)
        message = self.mod.hub_uninstall_tool(mock.Mock(), record)
        self.assertIn("Removed btop", message)
        self.mod.write_hub_apps.assert_called_once_with({})

    def test_hub_uninstall_refuses_core_packages(self):
        record = {
            "slug": "tmux",
            "name": "tmux",
            "kind": "apt",
            "package": "tmux",
        }
        message = self.mod.hub_uninstall_tool(mock.Mock(), record)
        self.assertIn("system package", message)

    def test_newer_system_index_wins_over_stale_cache(self):
        cache = Path(self.mod.hub_cache_path())
        cache.parent.mkdir(parents=True, exist_ok=True)
        cache.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "generated_at": "2026-01-01T00:00:00+00:00",
                    "apps": [{"id": "old", "name": "Old", "kind": "apt", "package": "old"}],
                }
            ),
            encoding="utf-8",
        )
        system = Path(self.mod.HUB_INDEX_SYSTEM)
        system.parent.mkdir(parents=True, exist_ok=True)
        system.write_text(
            json.dumps(
                {
                    "schema": 1,
                    "generated_at": "2026-11-20T00:00:00+00:00",
                    "apps": [{"id": "new", "name": "New", "kind": "apt", "package": "new"}],
                }
            ),
            encoding="utf-8",
        )
        loaded = self.mod.load_hub_index()
        self.assertEqual([app["id"] for app in loaded["apps"]], ["new"])

    def test_hub_index_without_catalog_is_empty(self):
        loaded = self.mod.load_hub_index()
        self.assertEqual(loaded["apps"], [])
        self.assertEqual(loaded["path"], "")


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
