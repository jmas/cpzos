"""Host-side checks for the Midnight Commander palette skin.

mc cannot read the CPZ theme files directly. It uses the ANSI palette that
cpz-foot-config installs in foot.ini, so the skin must reference palette slots
only, and every pair it uses must stay readable with every shipped palette.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
THEMES = FILES / "themes"
SKIN = FILES / "mc-skin.ini"

# mc's 16 ANSI names and the palette slot each one selects.
COLOR_SLOTS = {
    "black": 0,
    "red": 1,
    "green": 2,
    "brown": 3,
    "blue": 4,
    "magenta": 5,
    "cyan": 6,
    "lightgray": 7,
    "gray": 8,
    "brightred": 9,
    "brightgreen": 10,
    "yellow": 11,
    "brightblue": 12,
    "brightmagenta": 13,
    "brightcyan": 14,
    "white": 15,
}
ATTRIBUTES = {"bold", "italic", "underline", "reverse", "blink"}
# WCAG AA for normal text. The palettes are tuned above this, so a pair that
# drops below it means the theme palette and this skin no longer agree.
MIN_CONTRAST = 4.5

# mc takes frame characters from [Lines]; every key it does not find is drawn
# as a space, so a partial section means invisible borders. The group name is
# capitalised on purpose: mc <= 4.8.33 (Debian trixie) only reads "Lines".
LINE_KEYS = (
    "horiz",
    "vert",
    "lefttop",
    "righttop",
    "leftbottom",
    "rightbottom",
    "topmiddle",
    "bottommiddle",
    "leftmiddle",
    "rightmiddle",
    "cross",
    "dhoriz",
    "dvert",
    "dlefttop",
    "drighttop",
    "dleftbottom",
    "drightbottom",
    "dtopmiddle",
    "dbottommiddle",
    "dleftmiddle",
    "drightmiddle",
)

# Frame roles mc >= 4.8.34 reads from the skin. Older versions ignore them and
# use the section default, but every shipped skin should name them explicitly
# so a frame never inherits an invisible or content-coloured pair.
FRAME_KEYS = {
    "core": "frame",
    "dialog": "dframe",
    "error": "errdframe",
    "menu": "menuframe",
    "popupmenu": "menuframe",
    "help": "helpframe",
    "viewer": "viewframe",
    "editor": "editframe",
}


def load_palettes() -> dict[str, dict[int, str]]:
    palettes = {}
    for path in sorted(THEMES.glob("*.palette")):
        values = {}
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, value = line.split("=", 1)
            values[int(key)] = value
        palettes[path.stem] = values
    return palettes


def relative_luminance(color: str) -> float:
    channels = [int(color[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    linear = [
        c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
        for c in channels
    ]
    return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]


def contrast(first: str, second: str) -> float:
    high, low = sorted(
        (relative_luminance(first), relative_luminance(second)), reverse=True
    )
    return (high + 0.05) / (low + 0.05)


def parse_skin() -> dict[str, dict[str, str]]:
    sections: dict[str, dict[str, str]] = {}
    current = ""
    for line in SKIN.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = line[1:-1]
            sections[current] = {}
            continue
        key, value = line.split("=", 1)
        sections[current][key.strip()] = value.strip()
    return sections


def parse_color(spec: str) -> tuple[str, str, set[str]]:
    parts = [part.strip() for part in spec.split(";")]
    while len(parts) < 3:
        parts.append("")
    fg, bg, attributes = parts[0], parts[1], parts[2]
    return fg, bg, {a for a in attributes.split(",") if a}


def resolve(
    sections: dict[str, dict[str, str]], section: str, key: str
) -> tuple[str, str]:
    """Resolve empty fg/bg the way mc does: section default, then core."""
    fg, bg, _ = parse_color(sections[section].get(key, ""))
    core_fg, core_bg, _ = parse_color(sections["core"].get("_default_", ""))
    section_fg, section_bg, _ = parse_color(sections[section].get("_default_", ""))
    return (
        fg or section_fg or core_fg,
        bg or section_bg or core_bg,
    )


class McSkinTest(unittest.TestCase):
    def setUp(self) -> None:
        self.sections = parse_skin()
        self.palettes = load_palettes()

    def test_every_theme_palette_is_complete(self):
        self.assertTrue(self.palettes, "no theme palettes found")
        expected = set(range(16))
        for name, palette in self.palettes.items():
            with self.subTest(theme=name):
                self.assertEqual(set(palette), expected)
                for value in palette.values():
                    self.assertRegex(value, r"^[0-9a-fA-F]{6}$")

    def test_theme_conf_palette_matches_the_palette_file(self):
        # cpz-foot-config reads the "# palette N=" comments from the .conf
        # file. A stale comment would recolour foot and mc differently.
        for path in sorted(THEMES.glob("*.conf")):
            palette = self.palettes.get(path.stem)
            if palette is None:
                self.fail(f"{path.name} has no matching .palette file")
            comments = {}
            for line in path.read_text(encoding="utf-8").splitlines():
                match = re.match(r"^# palette (\d+)=([0-9a-fA-F]{6})$", line.strip())
                if match:
                    comments[int(match.group(1))] = match.group(2).lower()
            with self.subTest(theme=path.stem):
                self.assertEqual(
                    comments,
                    {slot: value.lower() for slot, value in palette.items()},
                )

    def test_skin_uses_palette_names_only(self):
        for section, values in self.sections.items():
            if section.lower() in ("skin", "lines"):
                continue
            for key, spec in values.items():
                fg, bg, attributes = parse_color(spec)
                with self.subTest(section=section, key=key):
                    for color in (fg, bg):
                        if color:
                            self.assertIn(
                                color,
                                COLOR_SLOTS,
                                f"{color!r} must name a palette slot, not a"
                                " fixed colour; mc has to follow the theme",
                            )
                    self.assertLessEqual(
                        attributes,
                        ATTRIBUTES,
                        f"unknown attributes in {spec!r}",
                    )

    def test_every_pair_is_readable_on_every_theme(self):
        for section, values in self.sections.items():
            if section.lower() in ("skin", "lines"):
                continue
            for key in values:
                fg, bg = resolve(self.sections, section, key)
                if not fg or not bg:
                    self.fail(f"[{section}] {key} does not resolve to a pair")
                for name, palette in self.palettes.items():
                    ratio = contrast(
                        palette[COLOR_SLOTS[fg]], palette[COLOR_SLOTS[bg]]
                    )
                    with self.subTest(section=section, key=key, theme=name):
                        self.assertGreaterEqual(
                            ratio,
                            MIN_CONTRAST,
                            f"[{section}] {key} = {fg};{bg} is {ratio:.2f}:1"
                            f" with {name}",
                        )

    def test_lines_section_draws_visible_borders(self):
        # mc <= 4.8.33 reads only the capitalised group and substitutes a
        # space for every missing key, which is what made panel and dialog
        # borders disappear on the device.
        self.assertIn("Lines", self.sections, "mc <= 4.8.33 only reads [Lines]")
        self.assertNotIn("lines", self.sections, "lowercase [lines] is dead on mc < 4.8.34")
        lines = self.sections["Lines"]
        self.assertEqual(set(lines), set(LINE_KEYS), "[Lines] keys must match mc's")
        for key in LINE_KEYS:
            value = lines[key]
            with self.subTest(key=key):
                self.assertEqual(len(value), 1, f"[Lines] {key} = {value!r} is not one cell")
                self.assertNotEqual(value, " ", f"[Lines] {key} is a blank frame")

    def test_frame_roles_are_explicit(self):
        for section, key in FRAME_KEYS.items():
            with self.subTest(section=section, key=key):
                self.assertIn(section, self.sections)
                self.assertTrue(
                    self.sections[section].get(key),
                    f"[{section}] {key} must name a frame pair",
                )

    def test_skin_is_wired_into_the_image(self):
        mc_ini = (FILES / "mc.ini").read_text(encoding="utf-8")
        self.assertIn("[Midnight-Commander]", mc_ini)
        self.assertIn("skin=cpz", mc_ini)
        run = (ROOT / "stage3" / "01-session" / "01-run.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("etc/mc/skins", run)
        self.assertIn('files/mc-skin.ini "${ROOTFS_DIR}/etc/mc/skins/cpz.ini"', run)


if __name__ == "__main__":
    unittest.main()
