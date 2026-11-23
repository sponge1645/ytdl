"""Downloader settings, URL classification and command construction."""
import json
from pathlib import Path
import re
from urllib.parse import parse_qs, urlsplit

VIDEO = ("best", "2160p", "1080p", "720p", "480p")
AUDIO = ("MP3", "M4A")
CONFIG = Path.home() / ".ytdl-settings.json"
DEFAULTS = {"instagram_browser": "", "video_output": "auto", "native_formats": ["mp4", "webm"], "video_preset": "standard",
            "language": "ru", "auto": False, "parallel": 3, "rate": 0, "proxy": "",
            "number_playlist_files": True, "playlist_separator": "-",
            "audio_folder": str(Path.home() / "Downloads"),
            "video_folder": str(Path.home() / "Downloads")}

_PROXY_CREDENTIALS = re.compile(r"""(?i)(\b[a-z][a-z0-9+.\-]*://)[^\s/?#'"<>]+@""")


_MALFORMED_PROXY_CREDENTIALS = re.compile(r"""(?i)(\b(?:https?|socks5h?)://)[^:/?#@\s'"<>]+:(?![0-9]+[/?#])[^\s'"<>]+@(?=[a-z0-9\[])""")

def redact_credentials(text):
    text = _MALFORMED_PROXY_CREDENTIALS.sub(r"\1[redacted]@", text)
    return _PROXY_CREDENTIALS.sub(r"\1[redacted]@", text)


def is_single_youtube_video(parsed):
    query = parse_qs(parsed.query)
    if query.get("list"):
        return False
    if parsed.hostname == "youtu.be":
        return bool(parsed.path.strip("/"))
    if parsed.hostname not in {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com"}:
        return False
    path = parsed.path.rstrip("/")
    if path == "/watch":
        return bool(query.get("v"))
    return path != "/embed/videoseries" and path.startswith(("/shorts/", "/live/", "/embed/"))


def read_preferences():
    try:
        saved = json.loads(CONFIG.read_text())
        return {**DEFAULTS, **saved}
    except (OSError, ValueError, TypeError):
        return DEFAULTS.copy()


def playlist_prefix(index, separator):
    separator = separator.strip()
    return f"{index:02d} {separator} " if separator else f"{index:02d} "


def is_instagram(url):
    return urlsplit(url).hostname in {"instagram.com", "www.instagram.com", "m.instagram.com"}


def download_command(executable, folder, mode, url, preferences, index=None,
                     restart=False, temporary=None, *, convert=False, preview=None):
    if mode == "Лучшее видео":
        mode = "best"
    if mode not in (*VIDEO, *AUDIO):
        raise ValueError("Unsupported download mode.")
    output = "%(title).150B.%(ext)s"
    if index is not None and preferences.get("number_playlist_files", True):
        prefix = playlist_prefix(index, preferences.get("playlist_separator", "-"))
        output = prefix.replace("%", "%%") + output
    command = [
        executable, "--ignore-config", "--no-playlist", "--no-simulate", "--no-quiet", "--progress", "--newline",
        "--print", "after_move:YTDL_FILE|%(filepath)j",
        "--progress-template", "download:YTDL|%(progress._percent_str)s|%(progress._speed_str)s|%(info.vcodec)s|%(progress.status)s",
        "-P", str(folder), "-o", output,
    ]
    if temporary is not None:
        command += ["-P", f"temp:{temporary}"]
    command += ["--force-overwrites", "--no-continue"] if restart else ["--continue"]
    if preview:
        title, referer, video = preview
        title = re.sub(r'[<>:"/\\|?*\x00-\x1f]', " ", title).strip(". ")
        title = title.encode("utf-8")[:150].decode("utf-8", errors="ignore").rstrip(". ") or "Artlist preview"
        command[command.index("-o") + 1] = title.replace("%", "%%") + ".%(ext)s"
        command += ["--referer", referer]
        if video:
            command += ["--remux-video", "mp4"]
    if mode in AUDIO:
        if mode == "MP3":
            command += ["-f", "bestaudio/best"]
        command += ["-x", "--audio-format", mode.lower(), "--audio-quality", "320K" if mode == "MP3" else "0"]
    elif not preview:
        limit = "" if mode == "best" else f"[height<={mode[:-1]}]"
        output_mode = preferences.get("video_output", "auto")
        if output_mode == "original":
            formats = preferences.get("native_formats", DEFAULTS["native_formats"])
            selectors = []
            merge_formats = []
            if "mp4" in formats:
                selectors.extend((f"bv*{limit}[ext=mp4]+ba[ext=m4a]", f"b{limit}[ext=mp4]"))
                merge_formats.append("mp4")
            if "webm" in formats:
                selectors.extend((f"bv*{limit}[ext=webm]+ba[ext=webm]", f"b{limit}[ext=webm]"))
                merge_formats.append("webm")
            if "flv" in formats:
                selectors.append(f"b{limit}[ext=flv]")
            command += ["-f", "/".join(selectors), "-S", "height"]
            if merge_formats:
                command += ["--merge-output-format", "/".join(merge_formats)]
        elif not convert and output_mode != "convert":
            h264 = "[ext~='^(mp4|mov)$'][vcodec~='^(avc1|avc3|h264)']"
            aac = "[acodec~='^(mp4a|aac)']"
            video = f"bv*{limit}{h264}[acodec~='^(none|mp4a|aac)']"
            audio = f"ba[ext~='^(m4a|mp4|mov)$']{aac}"
            combined = f"b{limit}{h264}{aac}"
            command += ["-f", f"{video}+{audio}/{combined}", "-S", "height",
                        "--merge-output-format", "mp4", "--remux-video", "mp4"]
        else:
            quality = 18 if output_mode == "convert" and preferences.get("video_preset") == "high" else 23
            command += ["-f", f"bv*{limit}+ba/b{limit}", "-S", "height",
                        "--merge-output-format", "mkv", "--recode-video", "mp4",
                        "--use-postprocessor", "FFmpegVideoRemuxer:when=post_process;preferedformat=mkv",
                        "--postprocessor-args",
                        f"VideoConvertor+ffmpeg_o:-c:v libx264 -crf {quality} -pix_fmt yuv420p -c:a aac -movflags +faststart"]
    if preferences["rate"]:
        command += ["--limit-rate", f'{preferences["rate"]}K']
    return command + ["--", url]
