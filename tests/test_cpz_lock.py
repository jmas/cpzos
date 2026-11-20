"""Host-side tests for the CPZ screensaver lock screen."""

from __future__ import annotations

import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout
from importlib.machinery import SourceFileLoader
from importlib.util import module_from_spec, spec_from_loader
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
LOCK = FILES / "cpz-lock"


def load_lock():
    loader = SourceFileLoader("cpz_lock", str(LOCK))
    spec = spec_from_loader(loader.name, loader)
    assert spec is not None
    module = module_from_spec(spec)
    loader.exec_module(module)
    return module


class UnlockSequenceTest(unittest.TestCase):
    def test_tab_then_enter_unlocks(self):
        sequence = load_lock().UnlockSequence()
        self.assertFalse(sequence.feed(b"\t"))
        self.assertTrue(sequence.feed(b"\r"))

    def test_enter_without_tab_does_not_unlock(self):
        sequence = load_lock().UnlockSequence()
        self.assertFalse(sequence.feed(b"\r"))
        self.assertFalse(sequence.feed(b"\n"))

    def test_other_key_clears_the_armed_tab(self):
        sequence = load_lock().UnlockSequence()
        self.assertFalse(sequence.feed(b"\t"))
        self.assertFalse(sequence.feed(b"a"))
        self.assertFalse(sequence.feed(b"\r"))

    def test_draw_shows_the_localized_unlock_hint(self):
        module = load_lock()
        output = io.StringIO()
        environment = {
            "CPZ_LANG": "en",
            "CPZ_I18N_DIR": str(FILES / "i18n"),
        }
        with mock.patch.dict(os.environ, environment, clear=False), mock.patch.object(
            module.os,
            "get_terminal_size",
            return_value=os.terminal_size((53, 14)),
        ), redirect_stdout(output):
            module.draw(module.UnlockSequence())
        text = output.getvalue()
        self.assertIn("Screen locked", text)
        self.assertIn("Press Tab, then Enter to unlock", text)


class MarkerTest(unittest.TestCase):
    def test_blank_marks_the_lock_and_restore_removes_it(self):
        module = load_lock()
        with tempfile.TemporaryDirectory() as temporary:
            module.MARKER = str(Path(temporary) / "screen.locked")
            calls = []
            module.run = lambda command, quiet=True: calls.append(command)
            module.blank()
            self.assertTrue(os.path.exists(module.MARKER))
            self.assertEqual(calls, [[module.BRIGHTNESS, "blank"]])
            module.restore()
            self.assertFalse(os.path.exists(module.MARKER))
            self.assertEqual(
                calls, [[module.BRIGHTNESS, "blank"], [module.BRIGHTNESS, "wake"]]
            )


if __name__ == "__main__":
    unittest.main()
