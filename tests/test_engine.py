import io
import json
import shlex
import subprocess
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from native import backend, tools_update
import dependencies


class EngineTests(unittest.TestCase):
    def test_youtube_cookie_retry_is_opt_in_and_scoped(self):
        error = "ERROR: [youtube] ID: Sign in to confirm you’re not a bot."
        with patch.object(backend, "tool_path", return_value="yt-dlp"), \
                patch.object(backend, "read_preferences", return_value={"proxy": "", "youtube_cookie_browser": "safari"}), \
                patch.object(backend.subprocess, "run") as run, patch("sys.stdout", new_callable=io.StringIO) as out:
            run.side_effect = [
                subprocess.CompletedProcess([], 1, stdout="", stderr=error),
                subprocess.CompletedProcess([], 0, stdout='{"title": "Video"}', stderr=""),
            ]
            backend.inspect("https://www.youtube.com/watch?v=0ZHnq7V-GXA")
        self.assertEqual(json.loads(out.getvalue().splitlines()[-1])["event"], "youtube_session")
        first, second = [call.args[0] for call in run.call_args_list]
        self.assertNotIn("--cookies-from-browser", first)
        self.assertEqual(second[-4:-2], ["--cookies-from-browser", "safari"])
        self.assertEqual(backend.youtube_cookie_retry("https://youtube.com.evil.test", {"youtube_cookie_browser": "safari"}, error), [])
        self.assertEqual(backend.youtube_cookie_retry("https://youtu.be/example", {}, error), [])

    def test_instagram_profile_post_link_is_normalized(self):
        with patch.object(backend, "read_preferences", return_value={"proxy": ""}), \
                patch.object(backend, "download_public_instagram") as download:
            backend.download({"url": "https://www.instagram.com/wylsacom/p/Df5J7JLRXi1/",
                              "mode": "best", "folder": "/output", "temporary": "/temporary"})
        download.assert_called_once_with("https://www.instagram.com/p/Df5J7JLRXi1/",
                                         Path("/output"), Path("/temporary"))

    def test_proxy_config_keeps_credentials_out_of_argv(self):
        proxy = "socks5h://user:p%27ass@host:1080"
        command = ["yt-dlp", "--ignore-config", "--", "https://example.com"]
        self.assertEqual(shlex.split(backend.proxy_config(command, proxy)), ["--proxy", proxy])
        self.assertEqual(command[1:3], ["--config-locations", "-"])
        self.assertNotIn(proxy, command)
        with self.assertRaises(ValueError):
            backend.proxy_config(command, "socks5h://host\n--verbose")

    def test_invalid_proxy_error_does_not_echo_credentials(self):
        for proxy in ("http://user:p%27ass#word@host:8080", "http://host:p%27ass", "http://host:65536"):
            with self.subTest(proxy=proxy), self.assertRaises(ValueError) as error:
                backend.proxy_config(["yt-dlp"], proxy)
            self.assertEqual(str(error.exception),
                             "Invalid proxy URL. Check the host and port and percent-encode credentials.")

    def test_inspect_excludes_hidden_entries_before_numbering(self):
        playlist = {"entries": [
            None,
            {"title": "[Deleted video]", "url": "https://example.com/deleted"},
            {"title": "Hidden", "availability": "private", "url": "https://example.com/private"},
            {"title": "Visible", "url": "https://example.com/video"},
        ]}
        with patch.object(backend, "tool_path", return_value="/bin/yt-dlp"), \
                patch.object(backend, "read_preferences", return_value={"proxy": ""}), \
                patch.object(backend.subprocess, "run") as run, patch("sys.stdout", new_callable=io.StringIO) as out:
            run.return_value.returncode = 0
            run.return_value.stdout = json.dumps(playlist)
            backend.inspect("https://example.com/playlist")
        self.assertEqual(json.loads(out.getvalue())["items"], [
            {"url": "https://example.com/video", "title": "Visible", "index": 1, "thumbnail": None},
        ])

    def test_cleanup_preserves_active_current_and_previous_kit(self):
        with TemporaryDirectory() as directory, patch.object(tools_update, "cache_root", return_value=Path(directory)):
            root = Path(directory)
            for version in ("1", "2", "3", "4"):
                (root / version).mkdir()
            (root / "current").write_text("4\n")
            self.assertEqual(tools_update.clean_old_kits("3"), 1)
            self.assertEqual({entry.name for entry in root.iterdir() if entry.is_dir()}, {"2", "3", "4"})

    def test_file_download_retries_connection_reset(self):
        reset = subprocess.CalledProcessError(56, "curl")
        with patch.object(dependencies.subprocess, "run", side_effect=[reset, None]) as run, \
                patch.object(dependencies.time, "sleep"):
            dependencies.download("https://example.com/tool", Path("test-tool"))
        self.assertEqual(run.call_count, 2)

    def test_download_keeps_https_on_redirects(self):
        with patch.object(dependencies.subprocess, "run") as run:
            dependencies.download("https://example.com/tool", Path("test-tool"))
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--proto") + 1], "=https")
        self.assertEqual(command[command.index("--proto-redir") + 1], "=https")
        self.assertTrue(run.call_args.kwargs["check"])
