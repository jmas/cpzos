"""Guard the persistent-state contract described in docs/STATE.md.

Runtime shell helpers must not write user-changeable state to /etc or /var.
The scan is deliberately conservative: it only looks at shell-style file
writes in ``stage3/01-session/files``. Python helpers are reviewed manually
against the deviation table in the document.

Each allowlist entry names a current exception and why it is acceptable.
When a deviation is fixed, delete the entry; this test fails if an entry no
longer matches, so the list cannot silently rot.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FILES = ROOT / "stage3" / "01-session" / "files"

# Absolute system paths that hold image-owned state.
TARGET = re.compile(r"/(?:etc|var/(?:lib|cache))/[A-Za-z0-9._/-]+")

# Shell constructs that create, replace or delete a file.
WRITE = re.compile(
    r"(^|[;&|(]\s*)(?:>|>>)"
    r"|\b(?:install|cp|mv|rm|touch|mkdir|chmod|chown|tee)\b"
    r"|\bsed\s+-i\b"
)

# Current deviations. Keep the reason next to the file so a reviewer can judge
# whether the exception is still justified.
ALLOWED = {
    "cancel-rename": (
        "removes raspi-config first-login leftovers; not user state"
    ),
    "cpz-locale-apply": (
        "known deviation: the system locale is still written to /etc "
        "(docs/STATE.md, priority P1)"
    ),
}


def shell_helpers() -> list[Path]:
    helpers = []
    for path in sorted(FILES.iterdir()):
        if not path.is_file():
            continue
        try:
            with path.open(encoding="utf-8", errors="replace") as handle:
                first = handle.readline()
        except OSError:
            continue
        if first.startswith("#!") and "sh" in first:
            helpers.append(path)
    return helpers


def find_out_of_home_writes() -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {}
    for path in shell_helpers():
        text = path.read_text(encoding="utf-8", errors="replace")
        for lineno, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            if TARGET.search(stripped) and WRITE.search(stripped):
                hits.setdefault(path.name, []).append(
                    f"{path.name}:{lineno}: {stripped}"
                )
    return hits


class StateContract(unittest.TestCase):
    def test_runtime_helpers_do_not_write_outside_home(self):
        hits = find_out_of_home_writes()
        unexpected = {
            name: lines for name, lines in hits.items() if name not in ALLOWED
        }
        self.assertFalse(
            unexpected,
            "Runtime helper writes user state outside /home. Move it under "
            "~/.config/cpz or ~/.local/state and see docs/STATE.md.\n"
            + "\n".join(
                line for lines in unexpected.values() for line in lines
            ),
        )

    def test_deviation_allowlist_is_current(self):
        hits = find_out_of_home_writes()
        stale = sorted(set(ALLOWED) - set(hits))
        self.assertFalse(
            stale,
            "These allowlist entries no longer match: "
            f"{stale}. Remove them from tests/test_state_contract.py and "
            "the deviation table in docs/STATE.md.",
        )


if __name__ == "__main__":
    unittest.main()
