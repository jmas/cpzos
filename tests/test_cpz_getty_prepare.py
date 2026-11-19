"""Host-side tests for the concurrent tty1 boot preparation."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
PREPARE = FILES / "cpz-getty-prepare"


class GettyPrepareTest(unittest.TestCase):
    def run_prepare(self, battery_rc: int = 0) -> tuple[subprocess.CompletedProcess, list[str]]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            log = root / "calls.log"

            def fake(name: str, rc: int) -> Path:
                path = root / name
                path.write_text(
                    "#!/bin/sh\n"
                    'printf "%s start\\n" "$0" >> "$CPZ_TEST_LOG"\n'
                    "sleep 0.6\n"
                    'printf "%s end\\n" "$0" >> "$CPZ_TEST_LOG"\n'
                    f"exit {rc}\n",
                    encoding="utf-8",
                )
                path.chmod(0o755)
                return path

            battery = fake("battery", battery_rc)
            display = fake("display", 0)
            script = root / "cpz-getty-prepare"
            script.write_text(
                PREPARE.read_text(encoding="utf-8")
                .replace("/usr/local/bin/cpz-battery", str(battery))
                .replace("/usr/local/bin/cpz-cage-output", str(display)),
                encoding="utf-8",
            )
            script.chmod(0o755)

            env = os.environ.copy()
            env["CPZ_TEST_LOG"] = str(log)
            result = subprocess.run(
                [str(script)],
                text=True,
                capture_output=True,
                env=env,
                timeout=10,
                check=False,
            )
            calls = log.read_text(encoding="utf-8").splitlines() if log.exists() else []
            return result, calls

    def test_boot_checks_run_concurrently_and_failures_are_ignored(self):
        result, calls = self.run_prepare(battery_rc=1)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(calls), 4, calls)
        # Both helpers must have started before either one finished. A
        # sequential ExecStartPre would produce start/end/start/end.
        self.assertTrue(calls[0].endswith(" start"), calls)
        self.assertTrue(calls[1].endswith(" start"), calls)
        self.assertTrue(calls[2].endswith(" end"), calls)
        self.assertTrue(calls[3].endswith(" end"), calls)


if __name__ == "__main__":
    unittest.main()
