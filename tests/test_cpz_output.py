"""Host-side tests for the CPZ kmscon output policy.

The real helper reads /sys, /proc and /run and talks to systemctl. These tests
run a copy with those paths redirected into a temporary root, so the settings
policy (especially display=panel and --auto) can be checked without hardware.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
OUTPUT = FILES / "cpz-kmscon-output"


class OutputPolicyTest(unittest.TestCase):
    def run_output(self, args):
        """Run cpz-kmscon-output against a fake display/settings tree."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home" / "cpz"
            user_settings = home / ".config" / "cpz" / "settings.conf"
            user_settings.parent.mkdir(parents=True)
            user_settings.write_text(
                "display=panel\nbrightness=100\n", encoding="utf-8"
            )

            system_settings = root / "etc" / "cpz" / "settings.conf"
            system_settings.parent.mkdir(parents=True)
            system_settings.write_text("", encoding="utf-8")

            drm = root / "sys" / "class" / "drm"
            hdmi = drm / "card0-HDMI-A-1"
            hdmi.mkdir(parents=True)
            (hdmi / "status").write_text("connected\n", encoding="utf-8")
            (hdmi / "enabled").write_text("enabled\n", encoding="utf-8")
            (hdmi / "edid").write_bytes(b"\x00" * 256)
            panel = drm / "card1-SPI-1"
            panel.mkdir(parents=True)
            (panel / "status").write_text("connected\n", encoding="utf-8")
            (panel / "enabled").write_text("disabled\n", encoding="utf-8")

            backlight = root / "sys" / "class" / "backlight" / "panel"
            backlight.mkdir(parents=True)
            (backlight / "max_brightness").write_text("255\n", encoding="utf-8")
            (backlight / "brightness").write_text("128\n", encoding="utf-8")
            (backlight / "bl_power").write_text("4\n", encoding="utf-8")

            cmdline = root / "proc" / "cmdline"
            cmdline.parent.mkdir(parents=True)
            cmdline.write_text("", encoding="utf-8")

            run_dir = root / "run" / "cpz-kmscon"
            helper = root / "bin" / "cpz-kmscon-config"
            helper.parent.mkdir(parents=True)
            helper.write_text("#!/bin/sh\nprintf 'same\\n'\n", encoding="utf-8")
            helper.chmod(0o755)

            systemctl = root / "bin" / "systemctl"
            systemctl.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  is-active | is-activating) exit 0 ;;\n"
                "esac\n"
                "exit 0\n",
                encoding="utf-8",
            )
            systemctl.chmod(0o755)
            logger = root / "bin" / "logger"
            logger.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            logger.chmod(0o755)

            script = root / "cpz-kmscon-output"
            text = OUTPUT.read_text(encoding="utf-8")
            text = text.replace(
                "first_home=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)",
                'first_home="$CPZ_TEST_HOME"',
            )
            text = text.replace("/run/cpz-kmscon", str(run_dir))
            text = text.replace("/sys/class/drm", str(drm))
            text = text.replace("/sys/class/backlight", str(root / "sys" / "class" / "backlight"))
            text = text.replace("/proc/cmdline", str(cmdline))
            text = text.replace("/etc/cpz/settings.conf", str(system_settings))
            text = text.replace("/usr/local/bin/cpz-kmscon-config", str(helper))
            script.write_text(text, encoding="utf-8")
            script.chmod(0o755)

            env = os.environ.copy()
            env["PATH"] = str(root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
            env["CPZ_TEST_HOME"] = str(home)
            env["HOME"] = str(home)
            result = subprocess.run(
                [str(script)] + args,
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=30,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"{args}: stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            state = (run_dir / "output.state").read_text(encoding="utf-8")
            brightness = (backlight / "brightness").read_text(encoding="utf-8").strip()
            bl_power = (backlight / "bl_power").read_text(encoding="utf-8").strip()
            return state, brightness, bl_power

    def test_panel_setting_wins_with_auto(self):
        # The systemd timer used to pass --auto, which must not override the
        # persisted display=panel setting.
        state, brightness, bl_power = self.run_output(["--auto"])
        self.assertIn("target=panel", state)
        self.assertNotEqual(brightness, "0")
        self.assertEqual(bl_power, "0")

    def test_panel_setting_wins_without_arguments(self):
        state, brightness, bl_power = self.run_output([])
        self.assertIn("target=panel", state)
        self.assertNotEqual(brightness, "0")
        self.assertEqual(bl_power, "0")

    def test_service_does_not_force_auto(self):
        service = (FILES / "cpz-kmscon-output.service").read_text(encoding="utf-8")
        self.assertNotIn("--auto", service)

    def test_kmscon_disables_original_mode(self):
        config = (FILES / "kmscon.conf").read_text(encoding="utf-8")
        self.assertIn("\nno-use-original-mode\n", config)


if __name__ == "__main__":
    unittest.main()
