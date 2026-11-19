"""Host-side tests for the CPZ image/video dispatcher."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILES = ROOT / "stage3" / "01-session" / "files"
OPEN = FILES / "cpz-open"


class OpenTest(unittest.TestCase):
    def run_open(self, name: str):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "calls.log"

            file_shim = bin_dir / "file"
            file_shim.write_text(
                "#!/bin/sh\n"
                'for last in "$@"; do :; done\n'
                'case "$last" in\n'
                '  *.png) echo "image/png" ;;\n'
                '  *.mp3) echo "audio/mpeg" ;;\n'
                '  *.mp4) echo "video/mp4" ;;\n'
                '  *) echo "text/plain" ;;\n'
                "esac\n",
                encoding="utf-8",
            )
            runner = bin_dir / "cpz-run"
            runner.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >>"$CPZ_TEST_LOG"\n',
                encoding="utf-8",
            )
            for shim in (file_shim, runner):
                shim.chmod(0o755)
            # `command -v imv-wayland` / `mpv` must succeed.
            for viewer in ("imv-wayland", "mpv", "cmus"):
                path = bin_dir / viewer
                path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
                path.chmod(0o755)

            music = bin_dir / "cpz-music"
            music.write_text(
                '#!/bin/sh\nprintf "cpz-music %s\\n" "$*" >>"$CPZ_TEST_LOG"\n',
                encoding="utf-8",
            )
            music.chmod(0o755)

            script = root / "cpz-open"
            text = (
                OPEN.read_text(encoding="utf-8")
                .replace("/usr/local/bin/cpz-run", str(runner))
                .replace("/usr/local/bin/cpz-music", str(music))
            )
            script.write_text(text, encoding="utf-8")
            script.chmod(0o755)

            media = root / name
            media.write_text("x", encoding="utf-8")

            env = os.environ.copy()
            env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
            env["CPZ_TEST_LOG"] = str(log)
            result = subprocess.run(
                [str(script), str(media)],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            calls = log.read_text(encoding="utf-8") if log.exists() else ""
            return result, calls

    def test_image_opens_in_imv(self):
        result, calls = self.run_open("photo.png")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls.startswith("imv-wayland "), calls)
        self.assertIn("photo.png", calls)

    def test_video_opens_in_mpv_with_the_software_output(self):
        result, calls = self.run_open("clip.mp4")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mpv --vo=wlshm --hwdec=no", calls)
        self.assertIn("clip.mp4", calls)

    def test_audio_opens_in_the_tui_player(self):
        result, calls = self.run_open("song.mp3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("cpz-music ", calls)
        self.assertIn("song.mp3", calls)
        self.assertNotIn("mpv --", calls)

    def test_apple_double_sidecar_opens_the_real_file(self):
        # macOS leaves "._song.mp3" next to "song.mp3"; it sorts first in mc
        # and is application/octet-stream, so the dispatcher maps it back.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "calls.log"

            file_shim = bin_dir / "file"
            file_shim.write_text(
                "#!/bin/sh\n"
                'for last in "$@"; do :; done\n'
                'case "$last" in\n'
                '  */._*) echo "application/octet-stream" ;;\n'
                '  *.mp3) echo "audio/mpeg" ;;\n'
                "esac\n",
                encoding="utf-8",
            )
            music = bin_dir / "cpz-music"
            music.write_text(
                '#!/bin/sh\nprintf "cpz-music %s\\n" "$*" >>"$CPZ_TEST_LOG"\n',
                encoding="utf-8",
            )
            cmus = bin_dir / "cmus"
            cmus.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            for shim in (file_shim, music, cmus):
                shim.chmod(0o755)

            script = root / "cpz-open"
            script.write_text(
                OPEN.read_text(encoding="utf-8").replace(
                    "/usr/local/bin/cpz-music", str(music)
                ),
                encoding="utf-8",
            )
            script.chmod(0o755)
            (root / "song.mp3").write_text("audio", encoding="utf-8")
            (root / "._song.mp3").write_text("sidecar", encoding="utf-8")

            env = os.environ.copy()
            env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
            env["CPZ_TEST_LOG"] = str(log)
            result = subprocess.run(
                [str(script), str(root / "._song.mp3")],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("cpz-music ", log.read_text(encoding="utf-8"))

    def test_other_files_are_left_to_the_caller(self):
        result, calls = self.run_open("notes.txt")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls, "")

    def _run_gallery(self, extra_files, viewer_status=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            bin_dir = root / "bin"
            bin_dir.mkdir()
            log = root / "calls.log"

            file_shim = bin_dir / "file"
            file_shim.write_text(
                "#!/bin/sh\n"
                'for last in "$@"; do :; done\n'
                'case "$last" in\n'
                '  */._*) echo "application/octet-stream" ;;\n'
                '  *.png) echo "image/png" ;;\n'
                "esac\n",
                encoding="utf-8",
            )
            viewer = bin_dir / "imv-wayland"
            viewer.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            runner = bin_dir / "cpz-run"
            runner.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$*" >>"$CPZ_TEST_LOG"\n'
                "exit \"${CPZ_TEST_VIEWER_STATUS:-0}\"\n",
                encoding="utf-8",
            )
            for shim in (file_shim, viewer, runner):
                shim.chmod(0o755)

            script = root / "cpz-open"
            script.write_text(
                OPEN.read_text(encoding="utf-8").replace(
                    "/usr/local/bin/cpz-run", str(runner)
                ),
                encoding="utf-8",
            )
            script.chmod(0o755)

            gallery = root / "gallery"
            gallery.mkdir()
            for name in ("0.CR2", "1.png", "2.png", "3.png", "4.psd", *extra_files):
                (gallery / name).write_text("x", encoding="utf-8")

            env = os.environ.copy()
            env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
            env["CPZ_TEST_LOG"] = str(log)
            env["CPZ_TEST_VIEWER_STATUS"] = str(viewer_status)
            result = subprocess.run(
                [str(script), str(gallery / "2.png")],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                timeout=15,
            )
            calls = log.read_text(encoding="utf-8") if log.exists() else ""
            return result, calls

    def test_images_open_as_a_gallery_of_the_directory(self):
        result, calls = self._run_gallery(["._2.png"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(calls.startswith("imv-wayland "), calls)
        # The opened file comes first, then its siblings in name order and no
        # macOS sidecars.
        gallery = Path(calls.split()[1]).parent
        self.assertEqual(
            calls.split(),
            [
                "imv-wayland",
                str(gallery / "2.png"),
                str(gallery / "0.CR2"),
                str(gallery / "1.png"),
                str(gallery / "3.png"),
                str(gallery / "4.psd"),
            ],
        )

    def test_an_interrupted_viewer_does_not_restart_the_file(self):
        # mc runs ${MC_XDG_OPEN} ... || do_open_action; a non-zero status after
        # Ctrl+C starts a second player. The dispatcher must report success.
        result, _ = self._run_gallery([], viewer_status=130)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lf_uses_the_dispatcher(self):
        lfrc = (FILES / "lfrc").read_text(encoding="utf-8")
        self.assertIn("/usr/local/bin/cpz-open", lfrc)
        self.assertIn("image/*|video/*|audio/*", lfrc)

    def test_mc_redirects_xdg_open(self):
        tmux = (FILES / "cpz-tmux").read_text(encoding="utf-8")
        self.assertIn("MC_XDG_OPEN /usr/local/bin/cpz-open", tmux)


if __name__ == "__main__":
    unittest.main()
