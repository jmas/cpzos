"""Host-side tests for the CPZ battery guard policy.

cpz-battery reads /sys/class/power_supply and powers off through systemctl.
These tests redirect the sysfs tree and PATH into a temporary directory, so
the thresholds and the boot hand-off can be checked without a device.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "stage3" / "01-session" / "files" / "cpz-battery"

SYSTEMCTL = """#!/bin/sh
printf '%s\\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
exit 0
"""


class BatteryGuardTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.supply = self.root / "power_supply" / "battery"
        self.supply.mkdir(parents=True)
        self.config = self.root / "battery.conf"
        self.run_dir = self.root / "run"
        self.run_dir.mkdir()
        self.bindir = self.root / "bin"
        self.bindir.mkdir()
        self.systemctl_log = self.root / "systemctl.log"
        self.write_script("systemctl", SYSTEMCTL)
        self.write_script("clear", "#!/bin/sh\nexit 0\n")
        # The boot countdown and the udev wait must not slow the test down.
        self.write_script("sleep", "#!/bin/sh\nexit 0\n")
        self.set_battery(50, "Discharging", 3900000, -420000)

    def write_script(self, name, content):
        path = self.bindir / name
        path.write_text(content, encoding="utf-8")
        path.chmod(0o755)
        return path

    def set_battery(self, capacity, status, voltage, current):
        (self.supply / "capacity").write_text(f"{capacity}\n", encoding="utf-8")
        (self.supply / "status").write_text(f"{status}\n", encoding="utf-8")
        (self.supply / "voltage_now").write_text(f"{voltage}\n", encoding="utf-8")
        (self.supply / "current_now").write_text(f"{current}\n", encoding="utf-8")

    def run_battery(self, *args):
        env = os.environ.copy()
        env.update(
            {
                "CPZ_BATTERY_SYSFS": str(self.root / "power_supply"),
                "CPZ_BATTERY_CONFIG": str(self.config),
                "CPZ_BATTERY_RUN": str(self.run_dir),
                "FAKE_SYSTEMCTL_LOG": str(self.systemctl_log),
                "PATH": f"{self.bindir}:{env['PATH']}",
            }
        )
        return subprocess.run(
            [str(SCRIPT), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )

    def test_status_reads_the_gauge(self):
        result = self.run_battery("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                "capacity=50",
                "status=Discharging",
                "voltage_now=3900000",
                "current_now=-420000",
                "charging=no",
            ],
        )

    def test_check_states(self):
        self.assertEqual(self.run_battery("check").stdout.strip(), "ok")

        self.set_battery(15, "Discharging", 3800000, -300000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (1, "low"))

        self.set_battery(10, "Discharging", 3700000, -300000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (2, "critical"))

    def test_charging_is_never_critical(self):
        self.set_battery(5, "Charging", 3600000, 180000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "charging"))

    def test_positive_current_counts_as_charging(self):
        # Some gauge/firmware combinations leave status at "Not charging".
        self.set_battery(8, "Not charging", 3600000, 120000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "charging"))

    def test_voltage_floor_catches_a_sagging_pack(self):
        self.set_battery(55, "Discharging", 3290000, -800000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (2, "critical"))

        self.config.write_text("shutdown_voltage_uv=0\n", encoding="utf-8")
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "ok"))

    def test_config_overrides_thresholds(self):
        self.config.write_text(
            "# comment\n"
            "warn_level=30\n"
            "shutdown_level=25  # inline comment\n"
            "boot_level=25\n",
            encoding="utf-8",
        )
        self.set_battery(20, "Discharging", 3800000, -300000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (2, "critical"))

    def test_invalid_config_keeps_defaults(self):
        self.config.write_text(
            "shutdown_level=abc\n"
            "warn_level=0\n"
            "shutdown_voltage_uv=1\n",
            encoding="utf-8",
        )
        self.set_battery(10, "Discharging", 3700000, -300000)
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (2, "critical"))

    def test_boot_powers_off_a_flat_pack(self):
        self.set_battery(9, "Discharging", 3500000, -300000)
        self.config.write_text(
            "boot_level=12\nshutdown_grace=0\n", encoding="utf-8"
        )
        result = self.run_battery("boot")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("too low to start safely", result.stdout)
        self.assertIn("Battery: 9% 3.5 V", result.stdout)
        self.assertIn("Powering off", result.stdout)
        self.assertEqual(
            self.systemctl_log.read_text(encoding="utf-8"),
            "poweroff --no-block\n",
        )

    def test_boot_continues_when_charging(self):
        self.set_battery(9, "Charging", 3600000, 180000)
        self.config.write_text("boot_level=12\n", encoding="utf-8")
        result = self.run_battery("boot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Charging - keep the charger connected", result.stdout)
        self.assertFalse(self.systemctl_log.exists())

    def test_boot_continues_with_enough_charge(self):
        result = self.run_battery("boot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.systemctl_log.exists())

    def test_missing_battery_is_not_an_error(self):
        (self.supply / "capacity").unlink()
        result = self.run_battery("check")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "unknown"))
        result = self.run_battery("boot")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.systemctl_log.exists())


if __name__ == "__main__":
    unittest.main()
