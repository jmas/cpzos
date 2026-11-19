"""Host-side tests for the CPZ language catalogs."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import subprocess
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
I18N = FILES / "cpz-i18n"
SETTINGS = FILES / "cpz-settings"


def load_script(name: str, path: Path):
    loader = SourceFileLoader(name, str(path))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class CatalogTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_i18n", I18N)
        old = os.environ.get("CPZ_LANG")
        os.environ.pop("CPZ_LANG", None)
        self.addCleanup(self.restore_env, "CPZ_LANG", old)

    def restore_env(self, name, old):
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old

    def test_all_catalogs_are_complete(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(self.mod.check_catalogs(), 0)
        self.assertIn("11 languages", output.getvalue())

    def test_site_and_device_languages_match(self):
        site = {
            path.stem
            for path in (ROOT / "site" / "i18n").glob("*.json")
        }
        self.assertEqual(set(self.mod.SUPPORTED), site)

    def test_translation_falls_back_to_english_then_source(self):
        self.assertEqual(self.mod.translate("Search", "uk"), "Пошук")
        self.assertEqual(self.mod.translate("Search", "de"), "Suche")
        self.assertEqual(
            self.mod.translate("This string does not exist", "uk"),
            "This string does not exist",
        )
        self.assertEqual(
            self.mod.translate("This string does not exist", "en"),
            "This string does not exist",
        )

    def test_placeholders_are_substituted(self):
        self.assertEqual(
            self.mod.translate("Rebind {name}", "de", name="Suche"),
            "Suche neu belegen",
        )

    def test_battery_and_tab_strings_are_translated(self):
        self.assertEqual(self.mod.translate("Discharging", "uk"), "Розряджається")
        self.assertEqual(self.mod.translate("Charging", "de"), "Wird geladen")
        self.assertEqual(self.mod.translate("Discharging", "es"), "Descargando")
        self.assertEqual(self.mod.translate("Power", "ja"), "電源")
        self.assertEqual(self.mod.translate("Power", "zh"), "电源")
        self.assertEqual(self.mod.translate("Settings", "fr"), "Paramètres")
        self.assertEqual(
            self.mod.translate("Close tab? (y/n)", "uk"),
            "Закрити вкладку? (y/n)",
        )
        self.assertEqual(
            self.mod.translate("Rename tab:", "de"),
            "Tab umbenennen:",
        )

    def test_radio_manager_strings_are_translated(self):
        self.assertEqual(self.mod.translate("Turn off", "uk"), "Вимкнути")
        self.assertEqual(self.mod.translate("Turn off", "de"), "Ausschalten")
        self.assertEqual(
            self.mod.translate("Scan complete", "es"), "Escaneo completado"
        )
        self.assertEqual(
            self.mod.translate("Forget {name}?", "fr", name="Home"),
            "Oublier Home ?",
        )

    def test_language_codes_normalize_locale_names(self):
        self.assertEqual(self.mod.normalize_language("uk_UA.UTF-8"), "uk")
        self.assertEqual(self.mod.normalize_language("de-DE"), "de")
        self.assertEqual(self.mod.normalize_language("en_US.UTF-8"), "en")
        self.assertEqual(self.mod.normalize_language("fr_FR.UTF-8"), "fr")
        self.assertEqual(self.mod.normalize_language("pl_PL.UTF-8"), "pl")
        self.assertEqual(self.mod.normalize_language("pt_BR.UTF-8"), "pt")
        self.assertEqual(self.mod.normalize_language("zh_CN.UTF-8"), "zh")
        self.assertEqual(self.mod.normalize_language("xx_XX.UTF-8"), "")

    def test_cli_reads_language_from_settings(self):
        with tempfile.TemporaryDirectory() as temporary:
            settings = Path(temporary) / "settings.conf"
            settings.write_text("language=de\n", encoding="utf-8")
            env = os.environ.copy()
            env["CPZ_I18N_SETTINGS"] = str(settings)
            result = subprocess.run(
                [str(I18N), "--value"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), "de")
            result = subprocess.run(
                [str(I18N), "--label"],
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.stdout.strip(), "Deutsch")


class SettingsLanguageTest(unittest.TestCase):
    def setUp(self):
        self.mod = load_script("cpz_settings_i18n", SETTINGS)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.mod.SYSTEM_SETTINGS = str(root / "etc" / "cpz" / "settings.conf")
        self.mod.THEME_DIR = str(root / "etc" / "cpz" / "themes")
        Path(self.mod.SYSTEM_SETTINGS).parent.mkdir(parents=True)
        Path(self.mod.THEME_DIR).mkdir(parents=True)
        for name in ("cpz-campbell", "cpz-homebrew"):
            (Path(self.mod.THEME_DIR) / f"{name}.conf").write_text(
                f"# name: {name}\n", encoding="utf-8"
            )
        old_config = os.environ.get("XDG_CONFIG_HOME")
        os.environ["XDG_CONFIG_HOME"] = str(root / "config")
        self.addCleanup(self.restore_env, "XDG_CONFIG_HOME", old_config)
        old_lang = os.environ.get("CPZ_LANG")
        os.environ.pop("CPZ_LANG", None)
        self.addCleanup(self.restore_env, "CPZ_LANG", old_lang)

    def restore_env(self, name, old):
        if old is None:
            os.environ.pop(name, None)
        else:
            os.environ[name] = old

    def test_system_page_offers_the_site_languages(self):
        items = self.mod.page_items("system", dict(self.mod.DEFAULTS), None)
        language = next(item for item in items if item["label"] == "Language")
        self.assertEqual(
            tuple(language["values"]()),
            ("en", "uk", "pl", "de", "fr", "es", "it", "pt", "tr", "ja", "zh"),
        )
        self.assertEqual(language["labels"]["uk"], "Українська")
        self.assertEqual(language["labels"]["ja"], "日本語")
        self.assertEqual(language["labels"]["zh"], "中文")

    def test_language_setting_round_trips(self):
        data = dict(self.mod.DEFAULTS)
        data["language"] = "uk"
        self.mod.save_settings(data)
        loaded = self.mod.load_settings()
        self.assertEqual(loaded["language"], "uk")
        self.assertEqual(self.mod.tr("Search"), "Пошук")

    def test_unknown_language_falls_back_to_english(self):
        data = dict(self.mod.DEFAULTS)
        data["language"] = "xx"
        self.mod.save_settings(data)
        self.assertEqual(self.mod.load_settings()["language"], "en")


if __name__ == "__main__":
    unittest.main()
