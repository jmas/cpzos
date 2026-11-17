"""Host-side tests for the cpz-automount helper.

The helper is a shell script that mounts real block devices. These tests source
it and check the pure helpers (label sanitising, mount options, mount-point
selection, device validation). The hotplug path itself is checked by
``tools/verify-image.sh`` and needs a Linux box with a USB disk.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "stage3" / "01-session" / "files" / "cpz-automount"


def run(function, *args, env=None):
    """Source the helper and call one shell function."""
    code = 'source "$1" || exit 1; shift; ' + function + ' "$@"'
    environment = os.environ.copy()
    environment.update(env or {})
    return subprocess.run(
        ["bash", "-c", code, "bash", str(SCRIPT), *args],
        capture_output=True,
        text=True,
        env=environment,
    )


def call(function, *args, env=None):
    result = run(function, *args, env=env)
    if result.returncode != 0:
        raise AssertionError(
            f"{function} failed ({result.returncode}): {result.stderr.strip()}"
        )
    return result.stdout.strip()


class SanitizeLabelTest(unittest.TestCase):
    def test_spaces_become_underscores(self):
        self.assertEqual(call("sanitize_label", "USB STICK"), "USB_STICK")

    def test_slashes_cannot_escape_the_mount_root(self):
        value = call("sanitize_label", "../../etc")
        self.assertNotIn("/", value)
        self.assertFalse(value.startswith("."))
        self.assertEqual(value, "_.._etc")

    def test_empty_and_dot_labels_fall_back_to_usb(self):
        self.assertEqual(call("sanitize_label", ""), "usb")
        self.assertEqual(call("sanitize_label", "."), "usb")
        self.assertEqual(call("sanitize_label", ".."), "usb")

    def test_long_labels_are_truncated(self):
        self.assertEqual(len(call("sanitize_label", "A" * 100)), 48)

    def test_non_ascii_labels_stay_in_one_path_component(self):
        value = call("sanitize_label", "Диск")
        self.assertTrue(value)
        self.assertTrue(all(ch.isascii() for ch in value))
        self.assertTrue(all(ch.isalnum() or ch in "._-" for ch in value))


class MountOptionsTest(unittest.TestCase):
    def test_fat_is_owned_by_the_console_user(self):
        self.assertEqual(
            call("mount_options", "vfat", "1000", "1000"),
            "uid=1000,gid=1000,umask=0022,iocharset=utf8,noatime",
        )

    def test_exfat_is_owned_by_the_console_user(self):
        self.assertEqual(
            call("mount_options", "exfat", "1000", "1000"),
            "uid=1000,gid=1000,umask=0022,iocharset=utf8,noatime",
        )

    def test_ntfs_uses_umask(self):
        self.assertEqual(
            call("mount_options", "ntfs", "1000", "1000"),
            "uid=1000,gid=1000,umask=0022,noatime",
        )

    def test_native_filesystems_keep_their_ownership(self):
        self.assertEqual(call("mount_options", "ext4", "1000", "1000"), "noatime")

    def test_ntfs_tries_the_kernel_driver_first(self):
        self.assertEqual(call("filesystem_types", "ntfs"), "ntfs3 ntfs")

    def test_other_filesystems_are_not_rewritten(self):
        self.assertEqual(call("filesystem_types", "ext4"), "ext4")


class ProbeFilesystemTest(unittest.TestCase):
    def fake_probe(self, *, fstype="", usage=""):
        """Run probe_filesystem against a fake blkid in PATH."""
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        fake = Path(temporary.name) / "blkid"
        lines = []
        if fstype:
            lines.append(f"ID_FS_TYPE={fstype}")
        if usage:
            lines.append(f"ID_FS_USAGE={usage}")
        body = "#!/bin/sh\n" + "".join(f"echo '{line}'\n" for line in lines)
        fake.write_text(body, encoding="utf-8")
        fake.chmod(0o755)
        result = run(
            "eval",
            "probe_filesystem /dev/fake; "
            'printf "%s:%s" "$PROBED_OK" "$PROBED_TYPE"',
            env={"PATH": f"{temporary.name}:{os.environ['PATH']}"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_mountable_filesystem_is_accepted(self):
        self.assertEqual(
            self.fake_probe(fstype="vfat", usage="filesystem"), "1:vfat"
        )

    def test_encrypted_partition_is_skipped(self):
        self.assertEqual(
            self.fake_probe(fstype="crypto_LUKS", usage="crypto"), "0:crypto_LUKS"
        )


class MountPointTest(unittest.TestCase):
    def test_uses_the_label_when_free(self):
        with tempfile.TemporaryDirectory() as temporary:
            value = call(
                "choose_mountpoint",
                "My_Disk",
                env={"CPZ_AUTOMOUNT_ROOT": temporary},
            )
            self.assertEqual(value, str(Path(temporary) / "My_Disk"))

    @unittest.skipUnless(
        shutil.which("mountpoint"), "needs util-linux mountpoint"
    )
    def test_does_not_mount_over_an_existing_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            occupied = Path(temporary) / "Data"
            occupied.mkdir()
            (occupied / "keep.txt").write_text("x", encoding="utf-8")
            value = call(
                "choose_mountpoint",
                "Data",
                env={"CPZ_AUTOMOUNT_ROOT": temporary},
            )
            self.assertEqual(value, str(Path(temporary) / "Data-2"))


class MountFlowTest(unittest.TestCase):
    def test_mount_uses_a_sanitised_label_and_console_uid(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fakebin = root / "bin"
            fakebin.mkdir()
            (root / "state").mkdir()

            def fake(name, body):
                path = fakebin / name
                path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
                path.chmod(0o755)

            record = root / "mount.args"
            tab_calls = root / "tab.calls"
            tab_helper = root / "cpz-tab-mount"
            tab_helper.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FAKE_TAB_CALLS"\n',
                encoding="utf-8",
            )
            tab_helper.chmod(0o755)
            fake("findmnt", "exit 1\n")
            fake("logger", "exit 0\n")
            fake(
                "blkid",
                'case "$*" in\n'
                '  *"-s LABEL"*) echo "USB STICK" ;;\n'
                '  *"-s UUID"*) echo "1234-5678" ;;\n'
                '  *"-o udev"*) printf "ID_FS_TYPE=vfat\\nID_FS_USAGE=filesystem\\n" ;;\n'
                "esac\n"
                "exit 0\n",
            )
            fake("mount", 'printf "%s\\n" "$*" >>"$FAKE_MOUNT_ARGS"\nexit 0\n')

            result = run(
                "eval",
                "do_mount /dev/fake",
                env={
                    "PATH": f"{fakebin}:{os.environ['PATH']}",
                    "CPZ_AUTOMOUNT_ROOT": str(root / "media"),
                    "CPZ_AUTOMOUNT_STATE": str(root / "state"),
                    "CPZ_AUTOMOUNT_USER": "cpz-user-that-does-not-exist",
                    "FAKE_MOUNT_ARGS": str(record),
                    "CPZ_AUTOMOUNT_TABS": str(tab_helper),
                    "FAKE_TAB_CALLS": str(tab_calls),
                },
            )
            self.assertEqual(result.returncode, 0, result.stderr)

            mountpoint = str(root / "media" / "USB_STICK")
            self.assertIn("-t vfat", record.read_text(encoding="utf-8"))
            self.assertIn("uid=1000,gid=1000", record.read_text(encoding="utf-8"))
            self.assertIn(mountpoint, record.read_text(encoding="utf-8"))
            self.assertEqual(
                tab_calls.read_text(encoding="utf-8").strip(),
                f"open {mountpoint} USB_STICK",
            )
            self.assertEqual(
                (root / "state" / "fake.mountpoint")
                .read_text(encoding="utf-8")
                .strip(),
                mountpoint,
            )


class MountTabHookTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = self.root / "tab.calls"
        self.helper = self.root / "cpz-tab-mount"
        self.helper.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$*" >>"$FAKE_TAB_CALLS"\n',
            encoding="utf-8",
        )
        self.helper.chmod(0o755)

    def hook_env(self, **values):
        environment = {
            "CPZ_AUTOMOUNT_TABS": str(self.helper),
            "FAKE_TAB_CALLS": str(self.calls),
        }
        environment.update(values)
        return environment

    def test_open_and_close_call_the_tab_helper(self):
        call(
            "open_mount_tab",
            "/media/USB",
            "USB",
            env=self.hook_env(),
        )
        call("close_mount_tabs", "/media/USB", env=self.hook_env())
        self.assertEqual(
            self.calls.read_text(encoding="utf-8").splitlines(),
            ["open /media/USB USB", "close /media/USB"],
        )

    def test_tabs_can_be_disabled(self):
        call(
            "open_mount_tab",
            "/media/USB",
            "USB",
            env=self.hook_env(CPZ_AUTOMOUNT_TAB="0"),
        )
        call(
            "close_mount_tabs",
            "/media/USB",
            env=self.hook_env(CPZ_AUTOMOUNT_TAB="0"),
        )
        self.assertFalse(self.calls.exists())

    def test_missing_helper_is_ignored(self):
        environment = self.hook_env(CPZ_AUTOMOUNT_TABS="/nonexistent/helper")
        call("open_mount_tab", "/media/USB", "USB", env=environment)
        call("close_mount_tabs", "/media/USB", env=environment)
        self.assertFalse(self.calls.exists())

    def test_unmount_closes_the_tab_before_unmounting(self):
        fakebin = self.root / "bin"
        fakebin.mkdir()
        mountpoint = self.root / "media" / "USB"
        mountpoint.mkdir(parents=True)
        state = self.root / "state"
        state.mkdir()
        (state / "fake.mountpoint").write_text(
            str(mountpoint) + "\n", encoding="utf-8"
        )
        events = self.root / "events"

        def fake(name, body):
            path = fakebin / name
            path.write_text("#!/bin/sh\n" + body, encoding="utf-8")
            path.chmod(0o755)

        fake("logger", "exit 0\n")
        fake("findmnt", f'echo "{mountpoint}"\n')
        fake("umount", 'printf "umount %s\\n" "$*" >>"$FAKE_EVENTS"\n')
        self.helper.write_text(
            '#!/bin/sh\nprintf "tab %s\\n" "$*" >>"$FAKE_EVENTS"\n',
            encoding="utf-8",
        )
        self.helper.chmod(0o755)

        result = run(
            "do_umount",
            "/dev/fake",
            env={
                "PATH": f"{fakebin}:{os.environ['PATH']}",
                "CPZ_AUTOMOUNT_STATE": str(state),
                "CPZ_AUTOMOUNT_TABS": str(self.helper),
                "FAKE_EVENTS": str(events),
            },
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            events.read_text(encoding="utf-8").splitlines(),
            [f"tab close {mountpoint}", f"umount -- {mountpoint}"],
        )
        self.assertFalse((state / "fake.mountpoint").exists())


class DelegationTest(unittest.TestCase):
    def test_overrides_disable_systemd_delegation(self):
        for key in (
            "CPZ_AUTOMOUNT_STATE",
            "CPZ_AUTOMOUNT_ROOT",
            "CPZ_AUTOMOUNT_USER",
            "CPZ_AUTOMOUNT_TAB",
            "CPZ_AUTOMOUNT_TABS",
        ):
            result = run(
                "delegate_to_systemd",
                "umount",
                "/dev/sda1",
                env={key: "test"},
            )
            self.assertEqual(result.returncode, 1, key)

    def test_service_execs_do_not_delegate_again(self):
        result = run(
            "delegate_to_systemd",
            "umount",
            "/dev/sda1",
            env={"INVOCATION_ID": "abc123"},
        )
        self.assertEqual(result.returncode, 1)


class DeviceValidationTest(unittest.TestCase):
    def test_paths_outside_dev_are_rejected(self):
        result = run("normalize_device", "../../etc/passwd")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "")

    def test_relative_block_names_get_a_dev_prefix(self):
        self.assertEqual(call("normalize_device", "sda1"), "/dev/sda1")


if __name__ == "__main__":
    unittest.main()
