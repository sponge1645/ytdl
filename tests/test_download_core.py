import unittest

from download_core import DEFAULTS, download_command, redact_credentials


class DownloadCoreTests(unittest.TestCase):
    def command(self, mode):
        return download_command("yt-dlp", "/tmp", mode, "https://example.com/video", DEFAULTS)

    def test_old_and_new_best_modes_are_equivalent(self):
        self.assertEqual(self.command("best"), self.command("Лучшее видео"))

    def test_resolution_is_a_ceiling(self):
        args = self.command("720p")
        self.assertIn("[height<=720]", args[args.index("-f") + 1])

    def test_audio_mode_preserves_requested_container(self):
        args = self.command("M4A")
        self.assertEqual(args[args.index("--audio-format") + 1], "m4a")

    def test_unescaped_proxy_password_delimiters_are_redacted(self):
        for delimiter in "/?#":
            with self.subTest(delimiter=delimiter):
                self.assertEqual(
                    redact_credentials(f"proxy=http://user:p{delimiter}ass@host:8080"),
                    "proxy=http://[redacted]@host:8080",
                )

    def test_url_with_port_and_at_in_path_is_preserved(self):
        url = "https://host:443/@name"
        self.assertEqual(redact_credentials(url), url)

    def test_proxy_credentials_are_redacted(self):
        self.assertEqual(
            redact_credentials("proxy=socks5h://user:p%40ss@host:1080"),
            "proxy=socks5h://[redacted]@host:1080",
        )
        self.assertEqual(redact_credentials("https://host/path@part"), "https://host/path@part")


if __name__ == "__main__":
    unittest.main()
