import json
from contextlib import nullcontext, redirect_stdout
from io import StringIO
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


RUN = runpy.run_path(str(Path(__file__).resolve().parents[1] / "music-track-smoke.py"))["run"]


class MusicSourceTests(unittest.TestCase):
    def test_youtube_link_can_switch_to_flac(self):
        attempts = RUN.__globals__["download_attempts"]
        self.assertEqual(next(attempts("ytmusic-spotiflac", None, "FLAC")), ("tidal-web", "FLAC"))
        with self.assertRaisesRegex(RuntimeError, "does not offer FLAC"):
            next(attempts("spotify-web", "ytmusic-spotiflac", "FLAC"))

    def test_automatic_dolby_tries_other_providers_until_flac_is_found(self):
        self.check_download(None, "track_not_found", ["amazon", "tidal-web", "qobuz-web"], True)

    def test_dolby_provider_errors_allow_automatic_flac(self):
        for error in ("api_error", "timeout"):
            with self.subTest(error=error):
                self.check_download(None, error, ["amazon", "tidal-web", "qobuz-web"], True)

    def test_media_tools_use_active_architecture_kit(self):
        media_tool = RUN.__globals__["media_tool"]
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder)
            kit = home / "Library/Application Support/YTDL/tool-kits-v1/arm64"
            bin_dir = kit / "42/bin"
            bin_dir.mkdir(parents=True)
            (kit / "current").write_text("42\n", encoding="ascii")
            with patch.object(Path, "home", return_value=home), patch("platform.machine", return_value="arm64"):
                for name in ("ffmpeg", "ffprobe"):
                    tool = bin_dir / name
                    tool.touch(mode=0o755)
                    self.assertEqual(media_tool(name), str(tool))

    def test_manual_amazon_does_not_fall_back(self):
        self.check_download("amazon", "track_not_found", ["amazon"], False)

    def test_engine_error_does_not_trigger_fallback(self):
        self.check_download(None, "network_error", ["amazon"], False)

    def check_download(self, source, error_type, services, success):
        requests = []

        def engine_call(method, payload):
            if method != "downloadByStrategy":
                return {}
            request = json.loads(payload)
            requests.append(request)
            if request["service"] == "qobuz-web":
                path = Path(request["output_path"])
                path.write_bytes(b"fLaC")
                return {"success": True, "file_path": str(path)}
            return {"success": False, "error_type": error_type}

        def copy_tags(path, destination, track, codec):
            destination.write_bytes(path.read_bytes())
            return destination

        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            args = SimpleNamespace(app=root, output=root / "stage", inspect=False, gui=True,
                                   url="https://music.youtube.com/watch?v=example",
                                   source=source, format="M4A-DDP",
                                   track_json='{"name":"Song","artists":"Artist","id":"video-id","isrc":"test-isrc"}')
            engine = Mock()
            engine.call.side_effect = engine_call
            with patch.dict(RUN.__globals__, {
                "open_music_engine": lambda *args: nullcontext(engine),
                "install_package": Mock(),
                "write_metadata": copy_tags,
            }), redirect_stdout(StringIO()):
                if success:
                    RUN(args, root)
                else:
                    with self.assertRaisesRegex(RuntimeError, error_type):
                        RUN(args, root)
            self.assertEqual(list(root.glob("*.flac")), [root / "Artist - Song.flac"] if success else [])
        self.assertEqual([request["service"] for request in requests], services)
        self.assertEqual(requests[0]["quality"], "eac3")
        self.assertTrue(all(request["isrc"] == "test-isrc" for request in requests))
        self.assertTrue(all("provider_track_id" not in request for request in requests))
