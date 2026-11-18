"""Unit tests for the CPZ shortcut registry (cpz-keys).

The rules are intentionally strict: one Alt key plus one plain key, unique
defaults, no punctuation/Sym/Fn chords, and one source of truth for tmux, help,
search and Settings.
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
KEYS = FILES / "cpz-keys"
SEARCH = FILES / "cpz-search"
SETTINGS = FILES / "cpz-settings"


def load_script(name: str, path: Path):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class KeysRegistry(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_keys", KEYS)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.mod.SYSTEM_KEYS = str(self.root / "etc" / "keys.conf")
        old_config = os.environ.get("XDG_CONFIG_HOME")
        old_cache = os.environ.get("XDG_CACHE_HOME")
        old_tmux = os.environ.get("CPZ_KEYS_TMUX_CONF")
        os.environ["XDG_CONFIG_HOME"] = str(self.root / "config")
        os.environ["XDG_CACHE_HOME"] = str(self.root / "cache")
        os.environ["CPZ_KEYS_TMUX_CONF"] = str(self.root / "tmux-keys.conf")
        self.addCleanup(self.restore_env, "XDG_CONFIG_HOME", old_config)
        self.addCleanup(self.restore_env, "XDG_CACHE_HOME", old_cache)
        self.addCleanup(self.restore_env, "CPZ_KEYS_TMUX_CONF", old_tmux)

    def restore_env(self, name, old):
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old

    def test_every_default_is_two_keys_with_alt(self):
        keys = [action["default"] for action in self.mod.ACTIONS]
        self.assertEqual(len(keys), len(set(keys)))
        for key in keys:
            self.assertTrue(self.mod.is_valid_key(key), key)
            self.assertTrue(key.startswith("M-"), key)
            self.assertEqual(key.count("-"), 1, key)
            self.assertNotRegex(key[2:], r"[+\-\[\]%=,./;'`]")
            self.assertNotIn("Shift", key)
            self.assertNotIn("Fn", key)

    def test_labels_fit_settings_and_actions_are_complete(self):
        ids = [action["id"] for action in self.mod.ACTIONS]
        self.assertEqual(len(ids), len(set(ids)))
        for action in self.mod.ACTIONS:
            self.assertLessEqual(len(action["label"]), 16, action)
            self.assertIn(action["section"], self.mod.SECTIONS)
            self.assertTrue(action["command"].strip(), action)
            self.assertTrue(action["label"].strip(), action)

    def test_search_popup_lets_the_cpz_frame_draw_the_title(self):
        search = next(
            action for action in self.mod.ACTIONS if action["id"] == "search"
        )
        self.assertIn("display-popup -B", search["command"])
        self.assertNotIn("-T ", search["command"])
        self.assertIn("-h 90%", search["command"])

    def test_normalize_accepts_config_forms_and_rejects_more_keys(self):
        self.assertEqual(self.mod.normalize_key("M-t"), "M-t")
        self.assertEqual(self.mod.normalize_key("m-t"), "M-t")
        self.assertEqual(self.mod.normalize_key("Alt+T"), "M-t")
        self.assertEqual(self.mod.normalize_key("alt + space"), "M-Space")
        for value in (
            "Ctrl+t",
            "C-t",
            "M-+",
            "M-Left",
            "Alt+Shift+T",
            "M-t-M-u",
            "",
        ):
            self.assertEqual(self.mod.normalize_key(value), "", value)

    def test_display_keys_are_human_readable(self):
        self.assertEqual(self.mod.display_key("M-t"), "Alt+T")
        self.assertEqual(self.mod.display_key("M-1"), "Alt+1")
        self.assertEqual(self.mod.display_key("M-Space"), "Alt+Space")
        self.assertEqual(self.mod.display_key(""), "unbound")

    def test_user_override_wins_and_default_keys_stay_unique(self):
        path = Path(self.mod.user_keys_path())
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("search=M-e\nnext-tab=M-t\n", encoding="utf-8")

        bindings = self.mod.effective_bindings()
        self.assertEqual(bindings["search"]["key"], "M-e")
        # next-tab tried to steal New Tab's default, so it falls back.
        self.assertEqual(bindings["next-tab"]["key"], "M-f")
        active = [binding["key"] for binding in bindings.values()]
        self.assertEqual(len(active), len(set(active)))

    def test_set_and_clear_override_round_trip(self):
        self.assertEqual(self.mod.set_override("search", "M-e"), 0)
        path = Path(self.mod.user_keys_path())
        self.assertIn("search=M-e", path.read_text(encoding="utf-8"))
        self.assertEqual(
            self.mod.effective_bindings()["search"]["key"], "M-e"
        )

        self.assertEqual(self.mod.set_override("search", "M-o"), 0)
        self.assertNotIn("search=", path.read_text(encoding="utf-8"))
        self.assertEqual(
            self.mod.effective_bindings()["search"]["key"], "M-o"
        )

        self.mod.clear_all_overrides()
        self.assertFalse(path.exists())

    def test_conflicts_and_invalid_keys_are_rejected(self):
        self.assertEqual(
            self.mod.conflict_for("search", "M-h"), "help"
        )
        self.assertEqual(self.mod.set_override("search", "M-h"), 2)
        self.assertEqual(self.mod.set_override("search", "Ctrl+q"), 2)
        self.assertEqual(self.mod.set_override("missing", "M-u"), 2)

    def test_write_config_unbinds_old_and_stale_keys(self):
        path = Path(self.mod.tmux_keys_path())
        self.mod.write_tmux_config(str(path))
        first = path.read_text(encoding="utf-8")
        self.assertIn("bind -n M-o ", first)
        self.assertIn("bind -n M-Space ", first)
        self.assertNotIn("unbind -n M-o", first)

        self.mod.set_override("search", "M-e")
        self.mod.write_tmux_config(str(path))
        second = path.read_text(encoding="utf-8")
        self.assertIn("unbind -n M-o", second)
        self.assertIn("bind -n M-e display-popup", second)
        self.assertNotIn("bind -n M-o ", second)

        self.mod.clear_all_overrides()
        self.mod.write_tmux_config(str(path))
        third = path.read_text(encoding="utf-8")
        self.assertIn("unbind -n M-e", third)
        self.assertIn("bind -n M-o ", third)

    def test_list_help_and_hint_use_the_registry(self):
        listing = self.mod.list_text()
        self.assertIn("search\tSearch\tStart here\tM-o\tAlt+O", listing)
        self.assertIn("Alt+Space", self.mod.help_text())
        self.assertEqual(
            self.mod.hint_text(),
            "Alt+H keys   Alt+O search   Alt+S settings",
        )

        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(self.mod.main(["help"]), 0)
        self.assertIn(
            "Every action is one modifier plus one key.", output.getvalue()
        )
        self.assertNotIn("CPZ shortcuts", output.getvalue())

    def test_tmux_conf_has_no_parallel_key_list(self):
        text = (FILES / "tmux.conf").read_text(encoding="utf-8")
        self.assertIn("cpz-keys write", text)
        self.assertIn("tmux-keys.conf", text)
        self.assertTrue(
            any(
                line.strip() == "source-file ~/.cache/cpz/tmux-keys.conf"
                for line in text.splitlines()
            )
        )
        for line in text.splitlines():
            self.assertFalse(line.lstrip().startswith("bind -n "), line)


class KeysConsumers(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        old_config = os.environ.get("XDG_CONFIG_HOME")
        old_cache = os.environ.get("XDG_CACHE_HOME")
        old_tmux = os.environ.get("CPZ_KEYS_TMUX_CONF")
        os.environ["XDG_CONFIG_HOME"] = str(self.root / "config")
        os.environ["XDG_CACHE_HOME"] = str(self.root / "cache")
        os.environ["CPZ_KEYS_TMUX_CONF"] = str(self.root / "tmux-keys.conf")
        self.addCleanup(self.restore_env, "XDG_CONFIG_HOME", old_config)
        self.addCleanup(self.restore_env, "XDG_CACHE_HOME", old_cache)
        self.addCleanup(self.restore_env, "CPZ_KEYS_TMUX_CONF", old_tmux)

    def restore_env(self, name, old):
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old

    def test_search_actions_come_from_the_registry(self):
        keys = load_script("cpz_keys_for_search", KEYS)
        search = load_script("cpz_search_for_keys", SEARCH)
        expected = [
            action["id"] for action in keys.ACTIONS if action["id"] != "search"
        ]
        self.assertEqual([action[0] for action in search.ACTIONS], expected)
        self.assertNotIn("scroll-history", [action[0] for action in search.ACTIONS])

    def test_capture_requires_alt(self):
        settings = load_script("cpz_settings_for_capture", SETTINGS)
        self.assertEqual(settings.shortcut_from_char(ord("t")), "")
        self.assertEqual(settings.shortcut_from_char(ord(" ")), "")
        self.assertEqual(settings.shortcut_from_char(1), "")
        self.assertEqual(
            settings.shortcut_from_char(ord("t"), alt_prefix=True), "M-t"
        )
        self.assertEqual(
            settings.shortcut_from_char(ord(" "), alt_prefix=True), "M-Space"
        )
        self.assertEqual(settings.shortcut_from_char(128 + ord("7")), "M-7")

    def test_settings_shortcuts_page_uses_registry_labels(self):
        keys = load_script("cpz_keys_for_settings", KEYS)
        settings = load_script("cpz_settings_for_keys", SETTINGS)
        data = dict(settings.DEFAULTS)
        items = settings.page_items("shortcuts", data, None)
        labels = [item["label"] for item in items]
        self.assertEqual(labels[:-1], [a["label"] for a in keys.ACTIONS])
        self.assertEqual(labels[-1], "Reset Shortcuts")
        self.assertEqual(
            settings.item_value(items[0], data), "Alt+O"
        )
        keyboard = [
            item["label"] for item in settings.page_items("keyboard", data, None)
        ]
        self.assertIn("Shortcuts", keyboard)


if __name__ == "__main__":
    unittest.main()
