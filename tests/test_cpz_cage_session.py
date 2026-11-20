"""Host-side test for the cage session supervisor.

The supervisor is the piece that makes a font or theme change replace only the
visible foot instead of restarting cage. This test uses a fake foot that records
its starts and SIGTERM, so the reload and shutdown paths are exercised without
hardware or a Wayland compositor.
"""

from __future__ import annotations

import os
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
SESSION = FILES / "cpz-cage-session"


class CageSessionTest(unittest.TestCase):
    def wait_for_starts(self, log: Path, count: int, timeout: float = 7.0) -> list[str]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if log.exists():
                lines = log.read_text(encoding="utf-8").splitlines()
                starts = [line for line in lines if line.startswith("start ")]
                if len(starts) >= count:
                    return lines
            time.sleep(0.05)
        self.fail(f"timed out waiting for {count} foot starts")

    def test_reload_replaces_only_the_visible_foot(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run_dir = root / "run" / "cpz-cage"
            run_dir.mkdir(parents=True)
            (run_dir / "foot.ini").write_text("font=Terminus:pixelsize=12\n")
            log = root / "foot.log"
            foot = root / "foot"
            foot.write_text(
                "#!/bin/sh\n"
                "printf 'start %s\\n' \"$$\" >>\"$CPZ_TEST_FOOT_LOG\"\n"
                "trap 'printf \"term %s\\n\" \"$$\" >>\"$CPZ_TEST_FOOT_LOG\";"
                " exit 0' TERM\n"
                "while :; do sleep 0.2; done\n",
                encoding="utf-8",
            )
            foot.chmod(0o755)

            script = root / "cpz-cage-session"
            text = SESSION.read_text(encoding="utf-8")
            text = text.replace("/run/cpz-cage", str(run_dir))
            text = text.replace("/usr/bin/foot", str(foot))
            text = text.replace("/usr/local/bin/cpz-tmux", str(root / "tmux"))
            script.write_text(text, encoding="utf-8")
            script.chmod(0o755)

            env = os.environ.copy()
            env["CPZ_TEST_FOOT_LOG"] = str(log)
            process = subprocess.Popen(
                [str(script)],
                cwd=root,
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                # The anchor starts first, then the visible foot.
                lines = self.wait_for_starts(log, 2)
                self.assertEqual(lines[0].split()[0], "start")
                self.assertEqual(lines[1].split()[0], "start")

                pid_file = run_dir / "cage-session.pid"
                foot_pid_file = run_dir / "foot.pid"
                ready_file = run_dir / "session.ready"
                deadline = time.monotonic() + 5
                while (
                    not pid_file.exists()
                    or not foot_pid_file.exists()
                    or not ready_file.exists()
                ) and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue(ready_file.exists())
                supervisor = int(pid_file.read_text(encoding="utf-8").strip())
                self.assertEqual(supervisor, process.pid)

                os.kill(process.pid, signal.SIGUSR1)
                lines = self.wait_for_starts(log, 3)
                self.assertTrue(
                    any(line.startswith("term ") for line in lines),
                    "the old visible foot was not terminated",
                )

                # A normal visible-foot exit (tmux detach) must end the session,
                # not silently respawn another terminal. The anchor is cleaned
                # up with it.
                last_start = [
                    line for line in lines if line.startswith("start ")
                ][-1]
                os.kill(int(last_start.split()[1]), signal.SIGTERM)
                self.assertEqual(process.wait(timeout=5), 0)
            finally:
                if process.poll() is None:
                    process.send_signal(signal.SIGTERM)
                    process.wait(timeout=5)
            self.assertFalse((run_dir / "cage-session.pid").exists())
            self.assertFalse((run_dir / "foot.pid").exists())


if __name__ == "__main__":
    unittest.main()
