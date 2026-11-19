"""Host-side tests for the CPZ cmus wrapper."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
MUSIC = FILES / "cpz-music"


class MusicWrapperTest(unittest.TestCase):
    def run_music(self, target: str | None, layout: dict[str, str]):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        calls = root / "calls.log"
        playlist = root / "playlist.txt"

        cmus = bin_dir / "cmus"
        cmus.write_text("#!/bin/sh\nsleep 0.3\nexit 0\n", encoding="utf-8")
        remote = bin_dir / "cmus-remote"
        remote.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = "-Q" ]; then printf "status playing\\n"; exit 0; fi\n'
            'printf "%s\\n" "$*" >>"$CPZ_TEST_LOG"\n'
            'case "$2" in\n'
            '  add\\ *) set -- $2; cp "$3" "$CPZ_TEST_PLAYLIST" ;;\n'
            "esac\n"
            "exit 0\n",
            encoding="utf-8",
        )
        for shim in (cmus, remote):
            shim.chmod(0o755)

        music = root / "music"
        music.mkdir()
        for name, body in layout.items():
            path = music / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(body, encoding="utf-8")

        env = os.environ.copy()
        env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
        env["TMPDIR"] = str(root)
        env["CPZ_TEST_LOG"] = str(calls)
        env["CPZ_TEST_PLAYLIST"] = str(playlist)
        args = [str(MUSIC)] if target is None else [str(MUSIC), str(music / target)]
        result = subprocess.run(
            args,
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
            timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        entries = playlist.read_text(encoding="utf-8").splitlines()
        return result, calls.read_text(encoding="utf-8").splitlines(), entries, root

    def test_selected_track_comes_first_then_the_rest_of_the_folder(self):
        result, calls, entries, root = self.run_music(
            "track-b.wav",
            {
                "track-b.wav": "b",
                "track-a.mp3": "a",
                "my song.flac": "c",
                "notes.txt": "not audio",
                "cover.cue": "cue sheet",
                "album/track-c.OGG": "d",
            },
        )
        self.assertEqual(calls[-1], "-C win-activate")
        self.assertEqual(entries[0], str(root / "music" / "track-b.wav"))
        self.assertEqual(entries[1:], [
            str(root / "music" / "album" / "track-c.OGG"),
            str(root / "music" / "my song.flac"),
            str(root / "music" / "track-a.mp3"),
        ])
        self.assertNotIn("notes.txt", "\n".join(entries))
        self.assertNotIn("cover.cue", "\n".join(entries))

    def test_hidden_metadata_is_not_queued(self):
        # macOS writes ._track.mp3 sidecars and .Trashes/.Spotlight folders;
        # they sort first and would stop the play queue on an unreadable file.
        _, _, entries, root = self.run_music(
            "track.mp3",
            {
                "track.mp3": "x",
                "._track.mp3": "apple double",
                "._notes.txt": "apple double",
                ".Trashes/track.mp3": "hidden",
                "second.mp3": "y",
            },
        )
        self.assertEqual(entries, [
            str(root / "music" / "track.mp3"),
            str(root / "music" / "second.mp3"),
        ])

    def test_queue_is_replaced_and_the_playlist_is_cleaned_up(self):
        _, calls, _, root = self.run_music("only.mp3", {"only.mp3": "x"})
        self.assertEqual(calls[0], "-C status")
        self.assertEqual(calls[1], "-C clear -q")
        self.assertEqual(calls[2], "-C clear -p")
        self.assertTrue(calls[3].startswith("-C add -p "), calls[3])
        self.assertEqual(calls[4], "-C view 3")
        self.assertEqual(calls[5], "-C win-top")
        self.assertEqual(calls[6], "-C win-activate")
        self.assertEqual(list(root.glob("cpz-music-*.pl")), [])

    def test_folder_order_is_rotated_to_the_opened_track(self):
        # 04, 05, ... 13, 01, 02, 03: the album keeps its order and wraps
        # instead of playing the clicked track and then starting from 01.
        _, _, entries, root = self.run_music(
            "b.mp3", {"a.mp3": "a", "b.mp3": "b", "c.mp3": "c", "d.mp3": "d"}
        )
        self.assertEqual(entries, [
            str(root / "music" / "b.mp3"),
            str(root / "music" / "c.mp3"),
            str(root / "music" / "d.mp3"),
            str(root / "music" / "a.mp3"),
        ])

    def test_a_single_file_queue_still_starts_playing(self):
        _, calls, entries, root = self.run_music("only.mp3", {"only.mp3": "x"})
        self.assertEqual(entries, [str(root / "music" / "only.mp3")])
        self.assertIn("-C win-activate", calls)

    def test_missing_argument_is_rejected(self):
        result = subprocess.run(
            [str(MUSIC)], text=True, capture_output=True, timeout=5
        )
        self.assertNotEqual(result.returncode, 0)

    def test_missing_file_is_rejected(self):
        result = subprocess.run(
            [str(MUSIC), "/nonexistent/track.mp3"],
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_option_like_path_is_rejected(self):
        result = subprocess.run(
            [str(MUSIC), "-rf"],
            text=True,
            capture_output=True,
            timeout=5,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
