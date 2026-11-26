import itertools
import json
import queue
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
    def test_music_playlist_retains_its_title(self):
        resolve = RUN.__globals__["resolve_collection"]
        engine = Mock()
        engine.call.return_value = {"type": "playlist", "playlist": {
            "title": "My Mix", "tracks": [{"name": "Song", "artists": "Artist"}, None],
        }}
        kind, tracks, skipped, title = resolve(engine, "https://open.spotify.com/playlist/example")
        self.assertEqual((kind, skipped, title), ("playlist", 1, "My Mix"))
        self.assertEqual([track["name"] for track in tracks], ["Song"])

    def test_music_album_uses_album_title_for_collection(self):
        resolve = RUN.__globals__["resolve_collection"]
        engine = Mock()
        track = {"name": "Song", "artists": "Artist", "album_name": "Track Album"}
        for album, title in [({"title": "Album from provider"}, "Album from provider"), ({}, "Track Album")]:
            with self.subTest(album=album):
                engine.call.return_value = {"type": "album", "album": album, "tracks": [track]}
                kind, tracks, skipped, collection_title = resolve(engine, "https://music.apple.com/album/example")
                self.assertEqual((kind, skipped, collection_title), ("album", 0, title))
                self.assertEqual(tracks[0]["name"], "Song")

    def test_verification_reports_repeated_challenge_as_failure(self):
        verify = RUN.__globals__["verify"]
        for result, expected in [({"success": True}, "true"), ({"error_type": "verification_required"}, "false")]:
            with self.subTest(result=result), patch.dict(RUN.__globals__, {
                "complete_browser_verification": Mock()
            }), redirect_stdout(StringIO()) as out:
                self.assertEqual(verify(Mock(), "amazon", True, lambda: result), result)
                self.assertEqual(out.getvalue().strip(), f"YTDL_VERIFICATION_RESULT {expected}")

    def test_youtube_link_can_switch_to_flac(self):
        attempts = RUN.__globals__["download_attempts"]
        self.assertEqual(next(attempts("ytmusic-spotiflac", None, "FLAC")), ("tidal-web", "FLAC"))
        with self.assertRaisesRegex(RuntimeError, "does not offer FLAC"):
            next(attempts("spotify-web", "ytmusic-spotiflac", "FLAC"))

    def test_automatic_dolby_tries_other_providers_until_flac_is_found(self):
        self.check_download(None, "track_not_found", ["amazon", "tidal-web", "qobuz-web"], True)

    def test_dolby_provider_errors_allow_automatic_flac(self):
        for error in ("api_error", "timeout", "network_error", "no_callback"):
            with self.subTest(error=error):
                self.check_download(None, error, ["amazon", "tidal-web", "qobuz-web"], True)

    def test_tidal_batch_uses_one_verification_and_routes_replies_by_track(self):
        download = RUN.__globals__["download_batch"]
        engine = Mock()
        engine.submit.side_effect = [1, 2, 3, 4]
        engine.wait_for_reply.side_effect = [(2, 0, b""), (1, 0, b""),
                                             (4, 0, b""), (3, 0, b"")]
        challenge = {"error_type": "verification_required"}
        engine.decode_reply.side_effect = [challenge, challenge, {"track": 1}, {"track": 0}]
        verify = Mock()
        finish = Mock(side_effect=lambda reply, *args: f"/out/{reply['track']}.flac")
        install = Mock()
        entries = [
            {"url": "https://open.spotify.com/album/example", "format": fmt,
             "track": json.dumps({"name": f"Song {i}", "artists": "Artist", "playlist_index": i + 1})}
            for i, fmt in enumerate(("MP3", "M4A"))
        ]
        with tempfile.TemporaryDirectory() as folder, patch.dict(RUN.__globals__, {
            "open_music_engine": lambda *args: nullcontext(engine),
            "install_package": install,
            "complete_browser_verification": verify,
            "finish_audio": finish,
        }), redirect_stdout(StringIO()) as out:
            root = Path(folder)
            download(SimpleNamespace(app=root, output=root / "out", batch=json.dumps(entries)), root)
        verify.assert_called_once_with(engine, "tidal-web", True)
        install.assert_called_once_with(engine, root, "tidal-web")
        self.assertEqual([call.args[0]["track"] for call in finish.call_args_list], [0, 1])
        self.assertEqual([call.args[3] for call in finish.call_args_list], ["MP3", "M4A"])
        submissions = [call.args[1] for call in engine.submit.call_args_list]
        self.assertEqual(submissions[:2], submissions[2:])
        self.assertTrue(all(json.loads(value)["output_ext"] == ".flac" for value in submissions))
        self.assertNotEqual(json.loads(submissions[0])["output_path"],
                            json.loads(submissions[1])["output_path"])
        self.assertIn('YTDL_BATCH_RESULT [1, {"file": "/out/1.flac"}]', out.getvalue())

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

    def test_manual_amazon_timeout_does_not_fall_back(self):
        self.check_download("amazon", "no_callback", ["amazon"], False)

    def test_engine_ignores_late_reply_after_timeout(self):
        engine_class = RUN.__globals__["Engine"]
        engine = engine_class.__new__(engine_class)
        engine.ids = itertools.count(1)
        engine.lib = Mock()
        engine.replies = Mock()
        engine.replies.get.side_effect = [
            queue.Empty,
            (1, 1, b'{"message":"cancelled"}'),
            (2, 0, b'{"success":true}'),
        ]
        with self.assertRaisesRegex(RUN.__globals__["EngineRequestError"], "timed out"):
            engine.call("downloadByStrategy", {})
        engine.lib.mornye_cancel.assert_called_once_with(1)
        self.assertEqual(engine.call("downloadByStrategy", {}), {"success": True})

    def test_automatic_compressed_formats_have_fallbacks(self):
        attempts = RUN.__globals__["download_attempts"]
        for audio_format in ("M4A", "MP3"):
            with self.subTest(audio_format=audio_format):
                plan = list(attempts("spotify-web", None, audio_format))
                self.assertEqual(plan[0], ("amazon", audio_format))
                self.assertIn(("ytmusic-spotiflac", audio_format), plan)
                self.assertTrue(all(fmt == audio_format for _, fmt in plan))

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
            if error_type == "no_callback":
                raise RUN.__globals__["EngineRequestError"]("downloadByStrategy timed out.")
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
                    message = {
                        "track_not_found": "track not found in Dolby Digital Plus",
                        "no_callback": "timed out",
                    }.get(error_type, error_type)
                    with self.assertRaisesRegex(RuntimeError, message):
                        RUN(args, root)
            self.assertEqual(list(root.glob("*.flac")), [root / "Artist - Song.flac"] if success else [])
        self.assertEqual([request["service"] for request in requests], services)
        self.assertEqual(requests[0]["quality"], "eac3")
        self.assertTrue(all(request["isrc"] == "test-isrc" for request in requests))
        self.assertTrue(all("provider_track_id" not in request for request in requests))
