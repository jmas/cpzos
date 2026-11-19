"""Host-side tests for the foot configuration renderer."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
FOOT_CONFIG = FILES / "cpz-foot-config"


class FootConfigTest(unittest.TestCase):
    def run_config(self, settings="font_size=14\n", theme=None, target=None):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home" / "cpz"
            user_settings = home / ".config" / "cpz" / "settings.conf"
            user_settings.parent.mkdir(parents=True)
            user_settings.write_text(settings, encoding="utf-8")
            system_settings = root / "etc" / "cpz" / "settings.conf"
            system_settings.parent.mkdir(parents=True)
            system_settings.write_text("", encoding="utf-8")
            themes = root / "etc" / "cpz" / "themes"
            themes.mkdir(parents=True)
            theme_text = theme or (
                "# name: Test\n"
                '# palette 0=0c0c0c\n'
                '# palette 1=ef2a3b\n'
                '# palette 2=13a10e\n'
                '# palette 3=c19c00\n'
                '# palette 4=4473ff\n'
                '# palette 5=cb32e0\n'
                '# palette 6=3a96dd\n'
                '# palette 7=cccccc\n'
                '# palette 8=7e7e7e\n'
                '# palette 9=e74856\n'
                '# palette 10=16c60c\n'
                '# palette 11=f9f1a5\n'
                '# palette 12=3b78ff\n'
                '# palette 13=e200c6\n'
                '# palette 14=61d6d6\n'
                '# palette 15=f2f2f2\n'
                'set -g window-style "bg=#0c0c0c,fg=#cccccc"\n'
            )
            (themes / "cpz-campbell.conf").write_text(theme_text, encoding="utf-8")

            run_dir = root / "run" / "cpz-cage"
            if target:
                run_dir.mkdir(parents=True, exist_ok=True)
                (run_dir / "output.state").write_text(
                    f"target={target}\n", encoding="utf-8"
                )
            script = root / "cpz-foot-config"
            text = FOOT_CONFIG.read_text(encoding="utf-8")
            text = text.replace(
                "first_home=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)",
                'first_home="$CPZ_TEST_HOME"',
            )
            text = text.replace("/run/cpz-cage", str(run_dir))
            text = text.replace("/etc/cpz/themes", str(themes))
            text = text.replace("/etc/cpz/settings.conf", str(system_settings))
            script.write_text(text, encoding="utf-8")
            script.chmod(0o755)

            env = os.environ.copy()
            env["CPZ_TEST_HOME"] = str(home)
            env["HOME"] = str(home)
            result = subprocess.run(
                [str(script)],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            config = (run_dir / "foot.ini").read_text(encoding="utf-8")
            return result, config

    def test_font_size_is_per_output(self):
        settings = "font_size_panel=12\nfont_size_hdmi=20\n"
        _, panel = self.run_config(settings=settings, target="panel")
        self.assertIn("font=Terminus:pixelsize=12", panel)
        _, hdmi = self.run_config(settings=settings, target="hdmi")
        self.assertIn("font=Terminus:pixelsize=20", hdmi)

    def test_unsupported_size_is_normalized_to_a_terminus_strike(self):
        # Terminus OTB only has bitmap strikes at 12/14/16/.../32. A persisted
        # 10 px (the old picker minimum) made foot fall back to a font without
        # Cyrillic, so Ukrainian labels rendered as dashes.
        _, config = self.run_config(settings="font_size_panel=10\n", target="panel")
        self.assertIn("font=Terminus:pixelsize=12", config)
        self.assertIn("font=DejaVu Sans Mono:pixelsize=12", config)

    def test_legacy_font_size_is_the_fallback(self):
        _, config = self.run_config(settings="font_size=18\n", target="hdmi")
        self.assertIn("font=Terminus:pixelsize=18", config)

    def test_renders_font_and_theme(self):
        result, config = self.run_config()
        self.assertEqual(result.stdout.strip(), "changed")
        self.assertIn("font=Terminus:pixelsize=14", config)
        self.assertIn("dpi-aware=no", config)
        self.assertIn("pad=0x0", config)
        self.assertIn("selection-target=clipboard", config)
        self.assertIn("[mouse]", config)
        self.assertIn("hide-when-typing=yes", config)
        self.assertIn("background=0c0c0c", config)
        self.assertIn("foreground=cccccc", config)
        self.assertIn("regular1=ef2a3b", config)
        self.assertIn("bright7=f2f2f2", config)

if __name__ == "__main__":
    unittest.main()
