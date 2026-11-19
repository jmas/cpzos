"""Host-side tests for the CPZ cage output policy.

The real helper reads /sys, /proc and /run and talks to systemctl. These tests
run a copy with those paths redirected into a temporary root, so the output
decision, the generated cage environment and the panel backlight can be
checked without hardware.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
OUTPUT = FILES / "cpz-cage-output"


class OutputPolicyTest(unittest.TestCase):
    def run_output(
        self,
        args,
        display="panel",
        hdmi="connected",
        edid=256,
        enabled="enabled",
        seed=None,
        layout_state=None,
    ):
        """Run cpz-cage-output against a fake display/settings tree."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home = root / "home" / "cpz"
            user_settings = home / ".config" / "cpz" / "settings.conf"
            user_settings.parent.mkdir(parents=True)
            user_settings.write_text(
                f"display={display}\nbrightness=100\n", encoding="utf-8"
            )

            system_settings = root / "etc" / "cpz" / "settings.conf"
            system_settings.parent.mkdir(parents=True)
            system_settings.write_text("", encoding="utf-8")

            drm = root / "sys" / "class" / "drm"
            hdmi_dir = drm / "card0-HDMI-A-1"
            hdmi_dir.mkdir(parents=True)
            (hdmi_dir / "status").write_text(hdmi + "\n", encoding="utf-8")
            (hdmi_dir / "enabled").write_text(enabled + "\n", encoding="utf-8")
            (hdmi_dir / "edid").write_bytes(b"\x00" * edid)
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

            systemd_dir = root / "etc" / "systemd" / "system"
            systemd_dir.mkdir(parents=True)

            run_dir = root / "run" / "cpz-cage"
            run_dir.mkdir(parents=True, exist_ok=True)
            for name, content in (seed or {}).items():
                (run_dir / name).write_text(content, encoding="utf-8")
            if layout_state is not None:
                (root / "run" / "cpz-layout.xkb").write_text(
                    layout_state, encoding="utf-8"
                )
            helper = root / "bin" / "cpz-foot-config"
            helper.parent.mkdir(parents=True)
            helper.write_text(
                "#!/bin/sh\nprintf 'same\\n'\n", encoding="utf-8"
            )
            helper.chmod(0o755)

            systemctl = root / "bin" / "systemctl"
            systemctl.write_text(
                "#!/bin/sh\n"
                "case \"$1\" in\n"
                "  is-active)\n"
                "    case \"$2\" in --quiet) exit 0 ;; esac\n"
                "    printf 'active\\n'; exit 0 ;;\n"
                "  is-activating) exit 0 ;;\n"
                "esac\n"
                "exit 0\n",
                encoding="utf-8",
            )
            systemctl.chmod(0o755)
            logger = root / "bin" / "logger"
            logger.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            logger.chmod(0o755)
            localectl = root / "bin" / "localectl"
            localectl.write_text(
                "#!/bin/sh\n"
                "printf 'System Locale: LANG=C.UTF-8\\n'\n"
                "printf '    X11 Layout: us\\n'\n",
                encoding="utf-8",
            )
            localectl.chmod(0o755)
            # xkb_settings wraps localectl in `timeout`. macOS has no timeout(1),
            # so without this shim the layout silently disappears from the
            # generated environment and the test would pass for the wrong
            # reason (an env change instead of the HDMI failure path).
            timeout = root / "bin" / "timeout"
            timeout.write_text(
                "#!/bin/sh\nshift\nexec \"$@\"\n", encoding="utf-8"
            )
            timeout.chmod(0o755)

            script = root / "cpz-cage-output"
            text = OUTPUT.read_text(encoding="utf-8")
            text = text.replace(
                "first_home=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)",
                'first_home="$CPZ_TEST_HOME"',
            )
            text = text.replace("/run/cpz-cage", str(run_dir))
            text = text.replace(
                "/run/cpz-layout.xkb", str(root / "run" / "cpz-layout.xkb")
            )
            text = text.replace("/sys/class/drm", str(drm))
            text = text.replace(
                "/sys/class/backlight", str(root / "sys" / "class" / "backlight")
            )
            text = text.replace("/proc/cmdline", str(cmdline))
            text = text.replace("/etc/cpz/settings.conf", str(system_settings))
            text = text.replace("/usr/local/bin/cpz-foot-config", str(helper))
            text = text.replace("/etc/systemd/system", str(systemd_dir))
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
                timeout=45,
            )
            self.assertEqual(
                result.returncode,
                0,
                f"{args}: stdout={result.stdout!r} stderr={result.stderr!r}",
            )
            state = ""
            state_path = run_dir / "output.state"
            if state_path.exists():
                state = state_path.read_text(encoding="utf-8")
            env_text = ""
            env_path = run_dir / "session.env"
            if env_path.exists():
                env_text = env_path.read_text(encoding="utf-8")
            brightness = (
                (backlight / "brightness").read_text(encoding="utf-8").strip()
            )
            bl_power = (
                (backlight / "bl_power").read_text(encoding="utf-8").strip()
            )
            return result, state, env_text, brightness, bl_power

    def test_published_xkb_layout_reaches_the_cage_environment(self):
        # cpz-keyboard-layout publishes the active layout because Debian's
        # dbus policy denies SetX11Keyboard to localed. localectl still reports
        # "us" in this harness; the published file must win, otherwise the
        # internal keyboard loses the CPZ Sym overlay.
        _result, _state, env_text, _brightness, _bl_power = self.run_output(
            ["--prepare"],
            display="panel",
            layout_state="layout=cpz_us\n",
        )
        self.assertIn("XKB_DEFAULT_LAYOUT='cpz_us'", env_text)

    def test_panel_setting_wins_with_auto(self):
        result, state, env_text, brightness, bl_power = self.run_output(
            ["--auto"], display="panel"
        )
        self.assertIn("target=panel", state)
        self.assertIn("/dev/dri/card1", env_text)
        self.assertIn("WLR_RENDERER='pixman'", env_text)
        self.assertNotEqual(brightness, "0")
        self.assertEqual(bl_power, "0")

    def test_auto_selects_hdmi_with_readable_edid(self):
        result, state, env_text, brightness, bl_power = self.run_output(
            ["--force"], display="auto", hdmi="connected", edid=256
        )
        self.assertIn("target=hdmi", state)
        # HDMI is the only card handed to cage: it must be the primary DRM
        # device, because the pixman renderer cannot scan out on a secondary
        # GPU (the panel card has no render node).
        self.assertIn("WLR_DRM_DEVICES='/dev/dri/card0'", env_text)
        self.assertIn("WLR_RENDERER='pixman'", env_text)
        self.assertEqual(brightness, "0")
        self.assertEqual(bl_power, "4")

    def test_each_target_uses_only_its_own_card(self):
        # A panel:HDMI multi-GPU list leaves HDMI as a secondary GPU. With
        # pixman that produces a cursor-only output, so the environment must
        # change when the target changes.
        result, state, panel_env, _brightness, _bl_power = self.run_output(
            ["--force"], display="panel", hdmi="connected", edid=256
        )
        self.assertIn("target=panel", state)
        self.assertIn("WLR_DRM_DEVICES='/dev/dri/card1'", panel_env)
        self.assertNotIn("card0", panel_env)

        result, state, hdmi_env, _brightness, _bl_power = self.run_output(
            ["--force"], display="auto", hdmi="connected", edid=256
        )
        self.assertIn("target=hdmi", state)
        self.assertIn("WLR_DRM_DEVICES='/dev/dri/card0'", hdmi_env)
        self.assertNotIn("card1", hdmi_env)
        self.assertNotEqual(panel_env, hdmi_env)

    def test_cage_receives_the_output_environment(self):
        # Sourcing the generated env file only creates shell variables. cage
        # must actually receive WLR_DRM_DEVICES/WLR_RENDERER; without them it
        # opens every DRM card and picks GLES2, which dies with
        # GL_OUT_OF_MEMORY on HDMI (the monitor blink loop).
        text = (FILES / "cpz-cage").read_text(encoding="utf-8")
        loader = text.split("load_env() {", 1)[1].split("\n}", 1)[0]
        self.assertIn("set -a", loader)
        self.assertIn("set +a", loader)
        self.assertIn("export WLR_DRM_DEVICES", text)
        self.assertIn("export WLR_RENDERER WLR_DRM_NO_MODIFIERS", text)

    def test_hdmi_switch_waits_for_a_stable_connector(self):
        # Leaving HDMI must survive one HPD pulse; entering HDMI is confirmed
        # with an extra probe. Both paths live in cpz-cage-output.
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("Do not move the session off a working HDMI link", text)
        self.assertIn("HDMI disappeared during confirmation", text)

    def test_auto_keeps_panel_without_edid(self):
        result, state, env_text, brightness, bl_power = self.run_output(
            ["--force"], display="auto", hdmi="connected", edid=0
        )
        self.assertIn("target=panel", state)
        self.assertIn("/dev/dri/card1", env_text)
        self.assertNotEqual(brightness, "0")

    def test_forced_hdmi_falls_back_when_unplugged(self):
        result, state, env_text, brightness, bl_power = self.run_output(
            ["--force"], display="hdmi", hdmi="disconnected"
        )
        self.assertIn("target=panel", state)
        self.assertIn("/dev/dri/card1", env_text)

    def test_target_and_status_are_machine_readable(self):
        result, state, _env, _brightness, _bl_power = self.run_output(
            ["--target"], display="panel"
        )
        self.assertEqual(result.stdout.strip(), "panel")
        result, _state, _env, _brightness, _bl_power = self.run_output(
            ["--status"], display="panel"
        )
        self.assertIn("target  : panel", result.stdout)
        self.assertIn("devices : /dev/dri/card1 (pixman)", result.stdout)
        self.assertIn("session : active", result.stdout)


    def test_failed_hdmi_attempt_returns_the_session_to_the_panel(self):
        # A connected monitor that cage never enables must not restart into the
        # same dead link: that is the monitor-blinking loop. One earlier failed
        # attempt plus this sample is enough to fall back to the panel.
        result, state, env_text, brightness, _bl_power = self.run_output(
            [],
            display="auto",
            hdmi="connected",
            edid=256,
            enabled="disabled",
            seed={
                "output.state": "target=hdmi\nmode=auto\n",
                "output.hdmi-fail": "1\n",
                # The already running session was started on the HDMI card.
                "session.env": (
                    "WLR_DRM_DEVICES='/dev/dri/card0'\n"
                    "WLR_RENDERER='pixman'\n"
                    "WLR_DRM_NO_MODIFIERS='1'\n"
                    "XKB_DEFAULT_LAYOUT='us'\n"
                ),
            },
        )
        self.assertIn("target=panel", state)
        self.assertIn("WLR_DRM_DEVICES='/dev/dri/card1'", env_text)
        self.assertNotEqual(brightness, "0")

    def test_auto_stops_choosing_hdmi_after_two_failures(self):
        # Until the cable is cycled or the user asks again, auto keeps the
        # working panel even while the monitor still reports connected.
        result, state, env_text, _brightness, _bl_power = self.run_output(
            [],
            display="auto",
            hdmi="connected",
            edid=256,
            seed={
                "output.state": "target=panel\nmode=auto\n",
                "output.hdmi-fail": "2\n",
            },
        )
        self.assertIn("target=panel", state)
        self.assertIn("WLR_DRM_DEVICES='/dev/dri/card1'", env_text)

    def test_replug_clears_the_hdmi_failure_history(self):
        # Unplugging is the user's chance to reseat the cable, so auto tries
        # HDMI again after the next plug.
        result, state, _env_text, _brightness, _bl_power = self.run_output(
            [],
            display="auto",
            hdmi="disconnected",
            seed={
                "output.state": "target=panel\nmode=auto\n",
                "output.hdmi-fail": "2\n",
            },
        )
        self.assertIn("target=panel", state)

    def test_automatic_restarts_are_rate_limited(self):
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("restart_gap=5", text)
        self.assertIn("restart_gap_inactive=20", text)
        self.assertIn("restart suppressed:", text)
        dropin = (
            FILES / "getty@tty1.service.d" / "10-cpz.conf"
        ).read_text(encoding="utf-8")
        self.assertIn("RestartMaxDelaySec=60", dropin)

    def test_report_mode_is_available(self):
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("--report)", text)
        self.assertIn("--report: --status plus", text)

    def test_prepare_does_not_wait_for_the_switching_helper(self):
        # --prepare runs from the getty's ExecStartPre while the helper that
        # started that getty still holds the lock. Waiting for it stalls the
        # switch for the whole timeout (8 s of every card change).
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("flock -n 9", text)
        self.assertIn("output environment already owned", text)
        # A message starting with a dash must not be parsed as a logger
        # option: logger then exits 1 and `set -e` kills the prepare, which
        # fails the getty unit and adds a systemd restart cycle to every switch.
        self.assertIn("logger -t cpz-cage-output --", text)

    def test_getty_does_not_pay_the_idle_start_delay(self):
        # getty@.service is Type=idle: systemd delays the start until the job
        # queue is empty. During a switch the queue holds the output helper
        # that called `systemctl start`, so every switch lost ~5 s.
        dropin = (
            FILES / "getty@tty1.service.d" / "10-cpz.conf"
        ).read_text(encoding="utf-8")
        self.assertIn("Type=simple", dropin)
        # A broken helper must not prevent the session from starting.
        self.assertIn("ExecStartPre=-+/usr/local/bin/cpz-getty-prepare", dropin)
        prepare = (FILES / "cpz-getty-prepare").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/cpz-battery boot", prepare)
        self.assertIn("/usr/local/bin/cpz-cage-output --prepare", prepare)
        self.assertIn("&", prepare)
        self.assertIn('wait "$display_pid"', prepare)
        self.assertIn('wait "$battery_pid"', prepare)

    def test_battery_boot_check_runs_once_per_boot(self):
        text = (FILES / "cpz-battery").read_text(encoding="utf-8")
        self.assertIn("cpz-battery.boot-checked", text)

    def test_user_request_bypasses_debounce_and_cooldown(self):
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("user_request=1", text)
        self.assertIn('[ "$user_request" = 0 ]', text)

    def test_panel_backlight_uses_the_pwm_channel(self):
        # The kernel backlight stack never programs the panel PWM (BL_CORE_FBBLANK
        # is never cleared), so the helper writes the m5ioe1 registers over I2C.
        # The backlight driver must stay bound: unbinding it removes the panel
        # DRM card through the device link.
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("cpz-panel-backlight off", text)
        self.assertIn('cpz-panel-backlight on "$percent"', text)
        helper = (FILES / "cpz-panel-backlight").read_text(encoding="utf-8")
        self.assertIn("/dev/i2c-", helper)
        self.assertIn("PWM_H", helper)
        self.assertIn("PWM_EN", helper)
        self.assertNotIn("/unbind", helper)
        brightness = (FILES / "cpz-brightness").read_text(encoding="utf-8")
        self.assertIn("cpz-panel-backlight", brightness)

    def test_timer_skips_unchanged_foot_config_and_backlight(self):
        # The five-second timer must not start Python or re-render foot.ini
        # when none of its inputs changed; both are cached under /run.
        text = OUTPUT.read_text(encoding="utf-8")
        self.assertIn("foot_config_stamp", text)
        self.assertIn("foot.stamp", text)
        self.assertIn("backlight.level", text)
        helper = (FILES / "cpz-panel-backlight").read_text(encoding="utf-8")
        self.assertIn("backlight.level", helper)
        # --force (suspend resume, display recovery) must bypass the caches.
        self.assertIn('[ "$force" = 0 ]', text)

    def test_service_does_not_force_auto(self):
        service = (FILES / "cpz-cage-output.service").read_text(encoding="utf-8")
        self.assertNotIn("--auto", service)

    def test_settings_path_unit_applies_output_changes_immediately(self):
        path = (FILES / "cpz-cage-output.path").read_text(encoding="utf-8")
        self.assertIn("PathModified=/run/cpz-cage/output.request", path)
        self.assertIn("Unit=cpz-cage-output.service", path)

    def test_udev_hotplug_uses_the_edid_aware_unit(self):
        rule = (FILES / "99-cpz-cage-output.rules").read_text(encoding="utf-8")
        self.assertIn("cpz-cage-output-hotplug.service", rule)

    def test_cage_runs_the_session_supervisor(self):
        cage = (FILES / "cpz-cage").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/cpz-cage-session", cage)

    def test_getty_uses_the_cage_login_session_on_tty1(self):
        dropin = (
            FILES / "getty@tty1.service.d" / "10-cpz.conf"
        ).read_text(encoding="utf-8")
        self.assertIn("cpz-getty", dropin)
        # cage only; the two boot checks are launched by the concurrent wrapper.
        self.assertIn("cpz-getty-prepare", dropin)
        profile = (FILES / "cpz-session.sh").read_text(encoding="utf-8")
        self.assertIn("/dev/tty1", profile)
        self.assertIn("/usr/local/bin/cpz-session-supervise", profile)


if __name__ == "__main__":
    unittest.main()
