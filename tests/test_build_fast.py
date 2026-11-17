"""Tests for the fast-stage build helper.

The helper is shell, but it only needs Docker to be present. These tests use a
fake docker binary and a fake build-docker.sh, so they verify the generated
STAGE_LIST/PREV_ROOTFS_DIR/compression config without building an image.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "build-fast.sh"


class BuildFastConfig(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "tools").mkdir()
        shutil.copy2(SCRIPT, self.root / "tools" / "build-fast.sh")

        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        docker.chmod(0o755)

        build = self.root / "build-docker.sh"
        build.write_text('#!/bin/sh\ncat "$2"\n', encoding="utf-8")
        build.chmod(0o755)

        (self.root / "config").write_text(
            "IMG_NAME=test-image\nDEPLOY_COMPRESSION=xz\n", encoding="utf-8"
        )

        self.env = os.environ.copy()
        self.env["PATH"] = f"{bin_dir}{os.pathsep}{self.env['PATH']}"
        self.env["DOCKER"] = "docker"

    def run_helper(self, *args: str, env: dict[str, str] | None = None):
        return subprocess.run(
            [str(self.root / "tools" / "build-fast.sh"), *args],
            cwd=self.root,
            env=env or self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )

    def test_stage3_uses_cached_stage2(self):
        result = self.run_helper("stage3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('STAGE_LIST="/pi-gen/stage3"', result.stdout)
        self.assertIn(
            'PREV_ROOTFS_DIR="/pi-gen/work/test-image/stage2/rootfs"',
            result.stdout,
        )
        self.assertIn("CLEAN=0", result.stdout)
        self.assertIn("DEPLOY_COMPRESSION=gz", result.stdout)
        self.assertEqual(list(self.root.glob(".build-fast.*")), [])

    def test_stage2_rebuilds_stage3_too(self):
        result = self.run_helper("stage2")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(
            'STAGE_LIST="/pi-gen/stage2 /pi-gen/stage3"',
            result.stdout,
        )
        self.assertIn(
            'PREV_ROOTFS_DIR="/pi-gen/work/test-image/stage1/rootfs"',
            result.stdout,
        )

    def test_compression_override(self):
        env = self.env.copy()
        env["FAST_COMPRESSION"] = "xz"
        result = self.run_helper("stage3", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DEPLOY_COMPRESSION=xz", result.stdout)

    def test_help_and_invalid_stage(self):
        help_result = self.run_helper("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn("Usage: tools/build-fast.sh", help_result.stdout)

        bad = self.run_helper("stage9")
        self.assertEqual(bad.returncode, 1)
        self.assertIn("unknown stage", bad.stderr)


if __name__ == "__main__":
    unittest.main()
