"""Unit tests for the os-list naming rules used by the release workflow."""

from __future__ import annotations

import importlib.util
import unittest
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
UPDATE_OS_LIST = ROOT / "scripts" / "update_os_list.py"


def load_module():
    loader = SourceFileLoader("update_os_list", str(UPDATE_OS_LIST))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class OsListNaming(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.mod = load_module()

    def test_semver_tags_are_shown_as_versions(self):
        self.assertEqual(self.mod.display_tag("v0.1.0"), "v0.1.0")
        self.assertEqual(self.mod.display_tag("0.1.0"), "v0.1.0")
        self.assertEqual(self.mod.display_tag("v0.2.0-beta.1"), "v0.2.0-beta.1")

    def test_legacy_timestamp_tags_drop_the_commit(self):
        self.assertEqual(
            self.mod.display_tag("20260608-102710-6a86c35"),
            "20260608-102710",
        )

    def test_entry_name_marks_prereleases(self):
        self.assertEqual(
            self.mod.os_entry_name("v0.1.0", False),
            "CardputerZero CPZ (Trixie arm64) v0.1.0",
        )
        self.assertEqual(
            self.mod.os_entry_name("v0.2.0-beta.1", True),
            "CardputerZero CPZ (Trixie arm64) v0.2.0-beta.1 (Beta)",
        )

    def test_versions_sort_numerically_newest_first(self):
        tags = ["v0.9.0", "v0.10.0", "v0.2.0", "v0.2.0-beta.1"]
        ordered = sorted(tags, key=self.mod.tag_sort_key, reverse=True)
        self.assertEqual(
            ordered,
            ["v0.10.0", "v0.9.0", "v0.2.0", "v0.2.0-beta.1"],
        )


if __name__ == "__main__":
    unittest.main()
