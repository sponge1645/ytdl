import io
import json
import shlex
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

from native import backend, tools_update
import dependencies


class EngineTests(unittest.TestCase):
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

    def test_download_keeps_https_on_redirects(self):
        with patch.object(dependencies.subprocess, "run") as run:
            dependencies.download("https://example.com/tool", Path("test-tool"))
        command = run.call_args.args[0]
        self.assertEqual(command[command.index("--proto") + 1], "=https")
        self.assertEqual(command[command.index("--proto-redir") + 1], "=https")
        self.assertTrue(run.call_args.kwargs["check"])
