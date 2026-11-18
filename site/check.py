#!/usr/bin/env python3
"""Check the static CPZ site before publishing it with GitHub Pages.

Verifies that every language file is valid, has the same keys as English and
keeps the same placeholders. Also checks that the HTML and the small runtime
only reference keys that exist.
"""

from __future__ import annotations

import json
import re
import sys
from html.parser import HTMLParser
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
I18N = ROOT / "i18n"
HTML = ROOT / "index.html"
APP = ROOT / "assets" / "app.js"
DYNAMIC_KEYS = {"meta.title", "meta.desc"}
PLACEHOLDER = re.compile(r"\{([a-zA-Z0-9_]+)\}")
VOID_TAGS = {
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}

errors: list[str] = []


class PageParser(HTMLParser):
    """Collect inline i18n text and placeholders from index.html."""

    def __init__(self) -> None:
        super().__init__()
        self.stack: list[dict[str, Any] | None] = []
        self.entries: list[dict[str, Any]] = []
        self.placeholders: list[tuple[str, str, int]] = []
        self.aria_labels: list[tuple[str, str, int]] = []
        self.title: list[str] = []
        self.description = ""
        self._in_title = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        values = dict(attrs)
        if tag == "meta" and values.get("name") == "description":
            self.description = values.get("content") or ""
        entry: dict[str, Any] | None = None
        if "data-i18n" in values:
            entry = {
                "key": values["data-i18n"],
                "text": [],
                "line": self.getpos()[0],
            }
            self.entries.append(entry)
        if "data-i18n-placeholder" in values:
            self.placeholders.append(
                (
                    values["data-i18n-placeholder"] or "",
                    values.get("placeholder") or "",
                    self.getpos()[0],
                )
            )
        if "data-i18n-aria-label" in values:
            self.aria_labels.append(
                (
                    values["data-i18n-aria-label"] or "",
                    values.get("aria-label") or "",
                    self.getpos()[0],
                )
            )
        if tag == "title":
            self._in_title += 1
        if tag not in VOID_TAGS:
            self.stack.append(entry)

    def handle_endtag(self, tag: str) -> None:
        if tag == "title":
            self._in_title = max(0, self._in_title - 1)
        if tag not in VOID_TAGS and self.stack:
            self.stack.pop()

    def handle_data(self, data: str) -> None:
        if self._in_title:
            self.title.append(data)
        for entry in self.stack:
            if entry is not None:
                text = entry["text"]
                assert isinstance(text, list)
                text.append(data)


def normalize(value: str) -> str:
    return " ".join(value.split())


def fail(message: str) -> None:
    errors.append(message)


def load(path: Path) -> dict[str, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{path.name}: {exc}")
        return {}
    if not isinstance(data, dict):
        fail(f"{path.name}: top level must be an object")
        return {}
    for key, value in data.items():
        if not isinstance(value, str) or not value.strip():
            fail(f"{path.name}: {key!r} must be a non-empty string")
    return data


def main() -> int:
    files = sorted(I18N.glob("*.json"))
    if not files:
        print("no language files found", file=sys.stderr)
        return 1

    en = load(I18N / "en.json")
    if not en:
        print("en.json is empty or invalid", file=sys.stderr)
        return 1

    for path in files:
        data = load(path)
        if not data:
            continue
        missing = set(en) - set(data)
        extra = set(data) - set(en)
        for key in sorted(missing):
            fail(f"{path.name}: missing key {key!r}")
        for key in sorted(extra):
            fail(f"{path.name}: unknown key {key!r}")
        for key in sorted(set(en) & set(data)):
            if set(PLACEHOLDER.findall(en[key])) != set(PLACEHOLDER.findall(data[key])):
                fail(f"{path.name}: placeholder mismatch in {key!r}")

    html = HTML.read_text(encoding="utf-8")
    used = set(re.findall(r'data-i18n(?:-placeholder|-aria-label)?="([^"]+)"', html))
    unknown = used - set(en) - DYNAMIC_KEYS
    for key in sorted(unknown):
        fail(f"index.html: unknown i18n key {key!r}")
    unused = set(en) - used - DYNAMIC_KEYS
    for key in sorted(unused):
        fail(f"en.json: key {key!r} is not referenced by the page")

    page = PageParser()
    page.feed(html)
    if normalize("".join(page.title)) != en["meta.title"]:
        fail("index.html: <title> does not match en.json meta.title")
    if normalize(page.description) != en["meta.desc"]:
        fail("index.html: meta description does not match en.json meta.desc")
    for entry in page.entries:
        key = str(entry["key"])
        expected = en.get(key)
        if expected is None:
            continue
        parts = entry["text"]
        assert isinstance(parts, list)
        if normalize("".join(parts)) != expected:
            fail(
                f"index.html:{entry['line']}: inline text for {key!r} "
                "does not match en.json"
            )
    for key, value, line in page.placeholders:
        expected = en.get(key)
        if expected is not None and normalize(value) != expected:
            fail(
                f"index.html:{line}: placeholder for {key!r} "
                "does not match en.json"
            )
    for key, value, line in page.aria_labels:
        expected = en.get(key)
        if expected is not None and normalize(value) != expected:
            fail(
                f"index.html:{line}: aria-label for {key!r} "
                "does not match en.json"
            )

    app = APP.read_text(encoding="utf-8")
    for key in sorted(DYNAMIC_KEYS):
        if key not in app:
            fail(f"app.js: dynamic key {key!r} is not referenced")
        if key not in en:
            fail(f"en.json: dynamic key {key!r} is missing")

    options = set(re.findall(r'<option value="([a-z]{2})"', html))
    languages = {path.stem for path in files}
    if options != languages:
        fail(
            "language selector does not match i18n/: "
            f"only in select {sorted(options - languages)}, "
            f"missing from select {sorted(languages - options)}"
        )

    if errors:
        for message in errors:
            print(f"FAIL: {message}", file=sys.stderr)
        print(f"{len(errors)} problem(s) found", file=sys.stderr)
        return 1

    print(f"site OK: {len(en)} keys, {len(files)} languages")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
