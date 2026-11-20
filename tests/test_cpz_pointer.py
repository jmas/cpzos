"""Host-side tests for the CPZ mouse and cursor policy.

The helper reads sysfs and the udev database. These tests build a fake
/sys/class/input tree, point cpz-pointer at it, and check which devices would
keep pointer capability. No hardware, root or udev daemon is needed.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
POINTER = FILES / "cpz-pointer"

# sysfs capability bitmaps are space-separated 64-bit words, most significant
# word first. BTN_LEFT (272) is bit 16 of word 4; BTN_TOUCH (330) is bit 10 of
# word 5; a full keyboard has bits 1..31 set in word 0.
REL_XY = "3"
BTN_LEFT = "10000 0 0 0 0"
BTN_TOUCH = "400 0 0 0 0 0"
FULL_KEYBOARD = "fffffffe"


class PointerPolicyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.sys = self.root / "sys" / "class" / "input"
        self.run_dir = self.root / "run" / "cpz-pointer"
        self.settings = self.root / "settings.conf"
        self.settings.write_text("mouse=0\n", encoding="utf-8")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.udev_log = self.root / "udev.log"
        udevadm = self.bin / "udevadm"
        udevadm.write_text(
            "#!/bin/sh\n"
            'printf "%s\\n" "$*" >>"$CPZ_TEST_UDEV_LOG"\n'
            "exit 0\n",
            encoding="utf-8",
        )
        udevadm.chmod(0o755)

    def add_device(
        self,
        event: str,
        *,
        name: str = "USB Optical Mouse",
        bus: str = "0003",
        rel: str = "0",
        abs_mask: str = "0",
        key: str = "0",
        properties: str = "0",
        path: str | None = None,
    ) -> Path:
        if path is None:
            path = f"devices/platform/usb1/{event}"
        event_dir = self.root / "sys" / path / "input" / event
        device_dir = event_dir / "device"
        (device_dir / "id").mkdir(parents=True)
        (device_dir / "capabilities").mkdir()
        (device_dir / "name").write_text(name + "\n", encoding="utf-8")
        (device_dir / "id" / "bustype").write_text(bus + "\n", encoding="utf-8")
        (device_dir / "capabilities" / "rel").write_text(rel + "\n", encoding="utf-8")
        (device_dir / "capabilities" / "abs").write_text(
            abs_mask + "\n", encoding="utf-8"
        )
        (device_dir / "capabilities" / "key").write_text(key + "\n", encoding="utf-8")
        (device_dir / "properties").write_text(properties + "\n", encoding="utf-8")
        self.sys.mkdir(parents=True, exist_ok=True)
        link = self.sys / event
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(event_dir)
        return event_dir

    def run_pointer(self, args: list[str], settings: str | None = None, extra_env=None):
        if settings is not None:
            self.settings.write_text(settings, encoding="utf-8")
        env = os.environ.copy()
        env.update(
            {
                "CPZ_SYSFS_ROOT": str(self.root / "sys"),
                "CPZ_POINTER_RUN_DIR": str(self.run_dir),
                "CPZ_POINTER_SETTINGS": str(self.settings),
                "CPZ_TEST_UDEV_LOG": str(self.udev_log),
                "PATH": str(self.bin) + ":" + env.get("PATH", ""),
            }
        )
        if extra_env:
            env.update(extra_env)
        result = subprocess.run(
            [sys.executable, str(POINTER), *args],
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
        return result

    def test_phantom_hdmi_pointer_keeps_keyboard_but_loses_pointer(self):
        self.add_device(
            "event0",
            name="vc4-hdmi",
            bus="001a",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )
        result = self.run_pointer(["--udev", "event0"], settings="mouse=1\n")
        # The pointer tags are removed by the udev rule (an IMPORT value cannot
        # delete a property); the hook marks the device instead.
        self.assertIn("CPZ_NO_POINTER=1", result.stdout)
        self.assertIn("ID_INPUT_KEYBOARD=1", result.stdout)
        self.assertNotIn("LIBINPUT_IGNORE_DEVICE=1", result.stdout)

    def test_real_mouse_is_stripped_while_mouse_support_is_off(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        result = self.run_pointer(["--udev", "event1"], settings="mouse=0\n")
        self.assertIn("CPZ_NO_POINTER=1", result.stdout)
        self.assertIn("LIBINPUT_IGNORE_DEVICE=1", result.stdout)
        self.assertIn("ID_SEAT=seat-cpz-no-pointer", result.stdout)
        self.assertIn("CPZ_REAL_POINTER=1", result.stdout)

    def test_real_mouse_is_kept_while_mouse_support_is_on(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        result = self.run_pointer(["--udev", "event1"], settings="mouse=1\n")
        # An enabled mouse must also clear the fake seat and the whole-device
        # ignore flag left behind by a previous "mouse off" event.
        self.assertIn("CPZ_REAL_POINTER=1", result.stdout)
        self.assertIn("ID_SEAT=seat0", result.stdout)
        self.assertIn("LIBINPUT_IGNORE_DEVICE=0", result.stdout)
        self.assertNotIn("seat-cpz-no-pointer", result.stdout)

    def test_internal_keyboard_pointer_bits_are_stripped(self):
        self.add_device(
            "event2",
            name="cardputer-zero-internal",
            bus="0018",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )
        result = self.run_pointer(["--udev", "event2"], settings="mouse=1\n")
        self.assertIn("CPZ_NO_POINTER=1", result.stdout)
        self.assertNotIn("LIBINPUT_IGNORE_DEVICE=1", result.stdout)

    def test_usb_keyboard_with_pointer_bits_is_not_a_mouse(self):
        self.add_device(
            "event4",
            name="USB Keyboard Consumer Control",
            bus="0003",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )
        result = self.run_pointer(["--json"], settings="mouse=1\n")
        state = json.loads(result.stdout)
        self.assertEqual(state["mouse"], "disconnected")
        self.assertEqual(state["cursor"], "hidden")

    def test_udev_mouse_tag_without_a_pointer_button_is_not_a_mouse(self):
        # input_id tags a device ID_INPUT_MOUSE from stray relative axes. The
        # tag alone must not make a keyboard count as a mouse and bring the
        # cursor back while no physical mouse is connected.
        self.add_device(
            "event6",
            name="USB Keyboard Consumer Control",
            bus="0003",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )
        result = self.run_pointer(
            ["--json"],
            settings="mouse=1\n",
            extra_env={"ID_INPUT_MOUSE": "1", "ID_INPUT_KEYBOARD": "1"},
        )
        state = json.loads(result.stdout)
        self.assertEqual(state["mouse"], "disconnected")
        self.assertEqual(state["cursor"], "hidden")

    def test_touchscreen_input_is_not_disabled_with_mouse_support_off(self):
        self.add_device(
            "event3",
            name="ADS7846 Touchscreen",
            bus="0018",
            abs_mask="3",
            key=BTN_TOUCH,
            properties="2",
        )
        result = self.run_pointer(["--udev", "event3"], settings="mouse=0\n")
        self.assertIn("ID_SEAT=seat0", result.stdout)
        self.assertNotIn("LIBINPUT_IGNORE_DEVICE", result.stdout)
        self.assertNotIn("ID_INPUT_MOUSE=0", result.stdout)

    def test_status_requires_both_a_mouse_and_the_setting(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        result = self.run_pointer(["--json"], settings="mouse=0\n")
        state = json.loads(result.stdout)
        self.assertEqual(state["mouse"], "connected")
        self.assertEqual(state["support"], "disabled")
        self.assertEqual(state["cursor"], "hidden")

        result = self.run_pointer(["--json"], settings="mouse=1\n")
        state = json.loads(result.stdout)
        self.assertEqual(state["cursor"], "visible")
        self.assertEqual(
            self.run_pointer(["--value", "cursor"], settings="mouse=1\n").stdout.strip(),
            "visible",
        )

    def test_no_mouse_keeps_the_cursor_hidden_even_when_enabled(self):
        self.add_device(
            "event0",
            name="vc4-hdmi",
            bus="001a",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )
        result = self.run_pointer(["--json"], settings="mouse=1\n")
        state = json.loads(result.stdout)
        self.assertEqual(state["mouse"], "disconnected")
        self.assertEqual(state["cursor"], "hidden")

    def test_apply_reopens_pointer_devices_once_per_policy_change(self):
        mouse = self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        self.add_device(
            "event2",
            name="Internal Keyboard",
            bus="0018",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )

        self.run_pointer(["--apply"], settings="mouse=0\n")
        lines = self.udev_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn("--action=remove", lines[0])
        self.assertIn("--action=add", lines[1])
        self.assertIn(str(mouse), lines[0])
        self.assertTrue(any(path.name == "state" for path in self.run_dir.iterdir()))

        # The signature is unchanged, so a second run must not disturb input.
        self.run_pointer(["--apply"], settings="mouse=0\n")
        self.assertEqual(
            len(self.udev_log.read_text(encoding="utf-8").splitlines()), 2
        )

        # Enabling the setting changes the policy and reopens the mouse again.
        self.run_pointer(["--apply"], settings="mouse=1\n")
        self.assertEqual(
            len(self.udev_log.read_text(encoding="utf-8").splitlines()), 4
        )

    def test_mouse_speed_is_published_for_the_cage_shim(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        self.run_pointer(["--apply"], settings="mouse=1\nmouse_speed=4\n")
        self.assertEqual(
            (self.run_dir / "speed").read_text(encoding="utf-8"), "0.4\n"
        )

        # A speed-only change changes the signature and reopens the pointer,
        # so libinput applies the new value without a compositor restart.
        self.udev_log.write_text("", encoding="utf-8")
        self.run_pointer(["--apply"], settings="mouse=1\nmouse_speed=-6\n")
        self.assertEqual(
            (self.run_dir / "speed").read_text(encoding="utf-8"), "-0.6\n"
        )
        self.assertEqual(
            len(self.udev_log.read_text(encoding="utf-8").splitlines()), 2
        )

        # Out-of-range settings are clamped to libinput's -1.0..1.0 range.
        self.run_pointer(["--apply"], settings="mouse=1\nmouse_speed=99\n")
        self.assertEqual(
            (self.run_dir / "speed").read_text(encoding="utf-8"), "1.0\n"
        )

    def test_nudge_clears_a_stale_cursor_without_restarting_cage(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        keyboard = self.add_device(
            "event2",
            name="Internal Keyboard",
            bus="0018",
            key=FULL_KEYBOARD,
        )
        self.run_pointer(["--nudge"], settings="mouse=0\n")
        lines = self.udev_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn("--action=remove", lines[0])
        self.assertIn(str(keyboard), lines[0])

    def test_reload_keymap_reopens_keyboards_only(self):
        mouse = self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        first = self.add_device(
            "event2",
            name="Internal Keyboard",
            bus="0018",
            key=FULL_KEYBOARD,
        )
        second = self.add_device(
            "event3",
            name="USB Keyboard",
            bus="0003",
            key=FULL_KEYBOARD,
        )
        self.run_pointer(["--reload-keymap"], settings="mouse=1\n")
        lines = self.udev_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 4)
        for device in (first, second):
            self.assertTrue(any(str(device) in line for line in lines))
        self.assertFalse(any(str(mouse) in line for line in lines))

    def test_nudge_does_not_touch_input_when_the_cursor_is_visible(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        self.add_device(
            "event2",
            name="Internal Keyboard",
            bus="0018",
            key=FULL_KEYBOARD,
        )
        self.run_pointer(["--nudge"], settings="mouse=1\n")
        self.assertFalse(self.udev_log.exists())

    def test_forced_nudge_clears_a_ghost_even_when_the_cursor_looks_visible(self):
        self.add_device("event1", rel=REL_XY, key=BTN_LEFT)
        keyboard = self.add_device(
            "event2",
            name="Internal Keyboard",
            bus="0018",
            key=FULL_KEYBOARD,
        )
        self.run_pointer(["--nudge", "--force"], settings="mouse=1\n")
        lines = self.udev_log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        self.assertIn(str(keyboard), lines[0])

    def test_combined_pointer_keeps_its_keyboard_half(self):
        # A combined keyboard/pointer must stay on seat0: moving it to the
        # fake seat would remove the keyboard too. Only its type tags change.
        self.add_device(
            "event5",
            name="USB Keyboard Consumer Control",
            bus="0003",
            rel=REL_XY,
            key=FULL_KEYBOARD,
        )
        result = self.run_pointer(["--udev", "event5"], settings="mouse=0\n")
        self.assertIn("ID_SEAT=seat0", result.stdout)
        self.assertIn("ID_INPUT_KEYBOARD=1", result.stdout)
        self.assertNotIn("seat-cpz-no-pointer", result.stdout)
        self.assertNotIn("LIBINPUT_IGNORE_DEVICE=1", result.stdout)

    def test_phantom_pointer_quirk_is_installed(self):
        quirks = (FILES / "60-cpz-phantom-pointer.quirks").read_text(
            encoding="utf-8"
        )
        self.assertIn("MatchName=cardputer-zero-internal", quirks)
        self.assertIn("MatchName=vc4-hdmi*", quirks)
        self.assertIn("AttrEventCode=-REL_X;-REL_Y;-ABS_X;-ABS_Y;", quirks)
        self.assertIn("MatchName=gpio_ir_recv", quirks)
        run = (ROOT / "stage3" / "01-session" / "01-run.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("60-cpz-phantom-pointer.quirks", run)
        self.assertIn("etc/libinput/local-overrides.quirks", run)

    def test_phantom_pointer_quirk_has_valid_sections(self):
        # A parse error in local-overrides.quirks disables every libinput
        # quirk, and repeated match keys are a parse error. Keep each section
        # to one MatchName and only known keys.
        sections: dict[str, set[str]] = {}
        current: set[str] | None = None
        path = FILES / "60-cpz-phantom-pointer.quirks"
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                name = line[1:-1].strip()
                self.assertTrue(name)
                self.assertNotIn(name, sections)
                current = sections[name] = set()
                continue
            self.assertIsNotNone(current, f"key outside a section: {line}")
            key = line.split("=", 1)[0]
            self.assertIn(key, {"MatchName", "AttrEventCode"})
            assert current is not None
            self.assertNotIn(key, current, f"duplicate {key} in one section")
            current.add(key)
        self.assertTrue(sections)

    def test_udev_rule_delegates_to_the_helper(self):
        rule = (FILES / "99-zz-cpz-input.rules").read_text(encoding="utf-8")
        self.assertIn(
            'IMPORT{program}="/usr/local/bin/cpz-pointer --udev %k"', rule
        )
        self.assertIn("CPZ_REAL_POINTER}", rule)
        self.assertIn("cpz-pointer-cursor.service", rule)
        # libinput checks whether an ID_INPUT_* property exists, so the pointer
        # tags must be deleted, not set to 0.
        self.assertIn("CPZ_NO_POINTER}", rule)
        self.assertIn("ENV{ID_INPUT_MOUSE}=\"\"", rule)
        self.assertIn('RUN+="/bin/systemctl --no-block start', rule)

    def test_path_unit_applies_mouse_setting_changes(self):
        path = (FILES / "cpz-pointer.path").read_text(encoding="utf-8")
        service = (FILES / "cpz-pointer.service").read_text(encoding="utf-8")
        apply_settings = (FILES / "cpz-apply-settings").read_text(encoding="utf-8")
        settings = (FILES / "cpz-settings").read_text(encoding="utf-8")
        cage_output = (FILES / "cpz-cage-output").read_text(encoding="utf-8")
        self.assertIn("PathModified=/run/cpz-pointer/request", path)
        self.assertIn("Unit=cpz-pointer.service", path)
        self.assertIn("/usr/local/bin/cpz-pointer --apply", service)
        self.assertIn("/usr/local/bin/cpz-pointer --apply", cage_output)
        self.assertIn("/run/cpz-pointer/request", apply_settings)
        self.assertIn('"/run/cpz-pointer/request"', settings)


if __name__ == "__main__":
    unittest.main()
