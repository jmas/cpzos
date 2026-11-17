"""Unit tests for the language-aware CPZ Sym overlay generator.

The helper turns `ckbcomp`'s console keymap into both the XKB layout and the VT
overlay. These tests use a synthetic ckbcomp table, so they do not need kbd or
xkb-data installed on the host.
"""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "stage3" / "01-session" / "files" / "cpz-layout-map"
TEMPLATE = ROOT / "stage3" / "01-session" / "files" / "xkb" / "symbols" / "cpz"


def load_helper():
    loader = SourceFileLoader("cpz_layout_map", str(HELPER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    assert spec is not None
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class LetterDetection(unittest.TestCase):
    def setUp(self):
        self.mod = load_helper()

    def test_unicode_letters_are_detected(self):
        for symbol in ("U+0445", "+U+0445", "+U+0407", "U+03b1"):
            self.assertTrue(self.mod.is_letter(symbol), symbol)

    def test_ascii_letters_are_detected(self):
        for symbol in ("q", "Z"):
            self.assertTrue(self.mod.is_letter(symbol), symbol)

    def test_punctuation_and_functions_are_not_letters(self):
        for symbol in (
            "U+0021",
            "+U+00ab",
            "exclam",
            "period",
            "KP_Home",
            "Henkan_Mode",
            "VoidSymbol",
            "U+0301",  # combining acute, not a letter by itself
            "",
            None,
        ):
            self.assertFalse(self.mod.is_letter(symbol), symbol)


class OverlayGeneration(unittest.TestCase):
    def setUp(self):
        self.mod = load_helper()
        self.header, self.entries, _trailer = self.mod.read_template(TEMPLATE)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def base_table(self):
        """A ckbcomp-style table: Ukrainian letters on the punctuation keys."""
        letters = {
            26: "+U+0445",  # х  (Sym+1)
            27: "+U+0457",  # ї  (Sym+2)
            39: "+U+0436",  # ж
            40: "+U+0454",  # є
            43: "+U+0491",  # ґ
            51: "+U+0431",  # б
            52: "+U+044e",  # ю
        }
        punctuation = {41: "U+0027", 53: "U+002e", 55: "U+007e", 69: "U+0060"}
        return {**punctuation, **letters}

    def run_helper(self, base: dict[int, str] | None, include: str, layout: str):
        base_path = Path(self.tmp.name) / "base.map"
        if base is None:
            base_arg = "-"
        else:
            base_arg = str(base_path)
            base_path.write_text(
                "\n".join(f"keycode {code} = {symbol}" for code, symbol in base.items())
                + "\n",
                encoding="utf-8",
            )
        xkb_out = Path(self.tmp.name) / "cpz.xkb"
        vt_out = Path(self.tmp.name) / "cpz.map"
        code = self.mod.main(
            [
                "cpz-layout-map",
                str(TEMPLATE),
                include,
                layout,
                base_arg,
                str(xkb_out),
                str(vt_out),
            ]
        )
        self.assertEqual(code, 0)
        return xkb_out.read_text(encoding="utf-8"), vt_out.read_text(encoding="utf-8")

    def test_latin_layout_keeps_the_static_punctuation_table(self):
        xkb, vt = self.run_helper(None, "us(basic)", "us")
        # Every punctuation entry is still present, with both levels equal.
        for entry in self.entries:
            self.assertIn(
                f"key <{entry.name}> {{ [ {entry.first}, {entry.second} ] }};", xkb
            )
        self.assertIn("include \"us(basic)\"", xkb)
        self.assertIn("CardputerZero internal (us)", xkb)
        self.assertEqual(len(vt.splitlines()) - 2, len(self.entries))

    def test_letters_are_left_to_the_layout_and_punctuation_moves(self):
        xkb, vt = self.run_helper(self.base_table(), "ua", "ua")

        # The letter keycodes are inherited from "ua"; overriding them would
        # destroy х, ї, ж, є, ґ, б and ю.
        for name in ("AD11", "AD12", "AC10", "AC11", "BKSL", "AB08", "AB09"):
            self.assertNotIn(f"key <{name}>", xkb)
            self.assertNotIn(f"keycode {self.entry_linux(name)} ", vt)

        # The displaced ASCII symbols are still reachable on level 2 of
        # punctuation-only keycodes.
        self.assertIn("key <TLDE> { [ percent, exclam ] };", xkb)
        self.assertIn("key <AB10> { [ parenleft, at ] };", xkb)
        self.assertIn("key <KPMU> { [ asciitilde, numbersign ] };", xkb)
        self.assertIn("key <KP7> { [ minus, ampersand ] };", xkb)
        self.assertIn("key <KP8> { [ plus, asterisk ] };", xkb)
        self.assertIn("keycode 41 = percent exclam", vt)
        self.assertIn("keycode 53 = parenleft at", vt)
        self.assertIn("keycode 55 = asciitilde numbersign", vt)
        self.assertIn("keycode 71 = minus ampersand", vt)

        # Nothing was lost: all punctuation symbols are still on some level.
        rendered = xkb + vt
        for symbol in (
            "exclam",
            "at",
            "numbersign",
            "dollar",
            "percent",
            "asciicircum",
            "ampersand",
            "asterisk",
            "parenleft",
            "parenright",
        ):
            self.assertIn(symbol, rendered)

    def entry_linux(self, name: str) -> int:
        return next(entry.linux for entry in self.entries if entry.name == name)

    def test_every_displaced_symbol_is_kept_when_slots_exist(self):
        base = {entry.linux: "+U+0430" for entry in self.entries[:7]}
        _xkb, vt = self.run_helper(base, "ua", "ua")
        # The first seven keycodes carry letters and are skipped; the eighth
        # keycode keeps its own symbol on level 1 and the first displaced one
        # on level 2.
        self.assertNotIn("keycode 26 ", vt)
        self.assertIn("keycode 52 = asterisk exclam", vt)


if __name__ == "__main__":
    unittest.main()
