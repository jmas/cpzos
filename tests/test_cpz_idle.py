"""Host-side tests for the CPZ idle screen-lock daemon."""

from __future__ import annotations

import os
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
IDLE = ROOT / "stage3" / "01-session" / "files" / "cpz-idle"


def load_idle():
    loader = SourceFileLoader("cpz_idle", str(IDLE))
    spec = spec_from_loader(loader.name, loader)
    assert spec is not None
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


class IdleTimeoutTest(unittest.TestCase):
    def write_settings(self, text: str) -> tuple[tempfile.TemporaryDirectory, Path]:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        config = Path(temporary.name) / "config"
        path = config / "cpz"
        path.mkdir(parents=True)
        (path / "settings.conf").write_text(text, encoding="utf-8")
        return temporary, config

    def test_timeout_is_read_from_the_user_settings(self):
        module = load_idle()
        _temporary, config = self.write_settings("screen_timeout=1\n")
        with mock.patch.dict(
            os.environ, {"XDG_CONFIG_HOME": str(config)}, clear=False
        ):
            self.assertEqual(module.timeout_seconds(), 60)

    def test_zero_and_invalid_values_disable_the_lock(self):
        module = load_idle()
        for value in ("0", "never", ""):
            _temporary, config = self.write_settings(
                f"screen_timeout={value}\n"
            )
            with mock.patch.dict(
                os.environ, {"XDG_CONFIG_HOME": str(config)}, clear=False
            ):
                self.assertEqual(module.timeout_seconds(), 0)

    def test_should_lock_at_the_configured_boundary(self):
        module = load_idle()
        self.assertFalse(module.should_lock(100.0, 159.9, 60))
        self.assertTrue(module.should_lock(100.0, 160.0, 60))
        self.assertFalse(module.should_lock(100.0, 999.0, 0))


if __name__ == "__main__":
    unittest.main()
