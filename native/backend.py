"""Command-line bridge between the native macOS window and the downloader."""
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import sys
from urllib.parse import urlsplit
from uuid import uuid4

from dependencies import BIN_DIR, install_missing, tool_path
from download_core import AUDIO, download_command, is_instagram, read_preferences as read_file_preferences, redact_credentials

os.environ["PATH"] = os.pathsep.join(
    [str(BIN_DIR), "/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "/usr/bin:/bin")]
)


_PROXY_OVERRIDE = os.environ.pop("YTDL_DOWNLOAD_PROXY", None)


def read_preferences():
    prefs = read_file_preferences()
    if _PROXY_OVERRIDE is not None:
        prefs["proxy"] = _PROXY_OVERRIDE
    return prefs


def emit(message, **fields):
    if isinstance(fields.get("status"), str):
        status = fields["status"]
        if _PROXY_OVERRIDE:
            status = status.replace(_PROXY_OVERRIDE, "[redacted proxy]")
        fields["status"] = redact_credentials(status)
    print(json.dumps({"event": message, **fields}, ensure_ascii=False), flush=True)


def proxy_config(command, proxy):
    if not proxy:
        return None
    try:
        if any(char.isspace() or ord(char) < 32 or ord(char) == 127 for char in proxy):
            raise ValueError
        address = urlsplit(proxy)
        port = address.port
        if (address.scheme not in {"http", "https", "socks5", "socks5h"}
                or not address.hostname or address.path not in {"", "/"}
                or "?" in proxy or "#" in proxy or address.netloc.endswith(":")
                or port == 0):
            raise ValueError
    except ValueError:
        raise ValueError("Invalid proxy URL. Check the host and port and percent-encode credentials.") from None
    command[1:1] = ["--config-locations", "-"]
    return f"--proxy {shlex.quote(proxy)}\n"


def inspect(url):
    if is_instagram(url):
        emit("items", items=[{"url": url, "title": "Instagram"}])
        return
    executable = tool_path("yt-dlp")
    if not executable:
        raise RuntimeError("yt-dlp is not installed yet.")
    prefs = read_preferences()
    command = [executable, "--ignore-config", "--flat-playlist", "--yes-playlist",
               "--compat-options", "no-youtube-unavailable-videos", "--dump-single-json",
               "--socket-timeout", "15"]
    config = proxy_config(command, prefs["proxy"])
    result = subprocess.run([*command, "--", url], input=config, capture_output=True, text=True, timeout=90)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "Unable to read this link.")
    data = json.loads(result.stdout)
    if "entries" not in data:
        emit("items", items=[{"url": url, "title": data.get("title") or url,
                             "thumbnail": data.get("thumbnail")}])
        return
    items = []
    for entry in data.get("entries") or []:
        if not entry or entry.get("availability") == "private":
            continue
        title = entry.get("title") or ""
        if title.strip("[] ").lower() in {"private video", "deleted video", "unavailable video"}:
            continue
        link = entry.get("webpage_url") or entry.get("url") or ""
        if link.startswith(("http://", "https://")):
            thumbnails = entry.get("thumbnails") or []
            items.append({"url": link, "title": title or link, "index": len(items) + 1,
                          "thumbnail": entry.get("thumbnail") or (thumbnails[-1].get("url") if thumbnails else None)})
    if not items:
        raise RuntimeError("No available playlist entries.")
    emit("items", items=items)


def download_public_instagram(url, folder, temp):
    from parth_dl import InstagramDownloader

    def progress(downloaded, total):
        if total:
            percent = f"{min(100, downloaded / total * 100):.1f}%"
            emit("progress", status=f"Downloading · {percent}", percent=percent)

    emit("log", status="Starting parth-dl (public Instagram)")
    staging = temp / "parth"
    staging.mkdir(parents=True, exist_ok=True)
    downloader = InstagramDownloader(quiet=True, rate_limit=True, overwrite=True,
                                     progress_hook=progress)
    files = downloader.download(url, output_path=str(staging))
    paths = [files] if isinstance(files, str) else files
    if not paths:
        raise RuntimeError("Instagram returned no files.")
    folder.mkdir(parents=True, exist_ok=True)
    for path in paths:
        source = Path(path)
        if source.resolve().parent != staging.resolve() or not source.is_file():
            raise RuntimeError("parth-dl returned an invalid output path.")
        destination = folder / source.name
        if destination.exists():
            destination = folder / f"{source.stem}-{uuid4().hex[:8]}{source.suffix}"
        shutil.move(source, destination)
        emit("file", path=str(destination))


def download(request):
    prefs = read_preferences()
    url, mode = request["url"], request["mode"]
    instagram = is_instagram(url)
    # Reel and legacy IGTV links are video-only. Posts may contain photo carousels.
    parts = urlsplit(url).path.strip("/").split("/") if instagram else []
    instagram_video = len(parts) >= 2 and parts[-2].lower() in {"reel", "reels", "tv"}
    folder = Path(request["folder"])
    temp = Path(request["temporary"])
    if instagram and not instagram_video:
        if len(parts) < 2 or parts[-2].lower() != "p":
            raise RuntimeError("Use a direct link to an Instagram post or Reel.")
        if prefs.get("proxy"):
            raise RuntimeError("Instagram photo posts require a direct connection in this app.")
        download_public_instagram(url, folder, temp)
        return

    executable = tool_path("yt-dlp")
    if not executable:
        raise RuntimeError("Download tools are still being installed.")
    if instagram_video and mode in AUDIO:
        mode = "best"
    options = dict(index=request.get("index"), temporary=temp)
    args = executable, folder, mode, url, prefs
    commands = [download_command(*args, **options)]
    if mode not in AUDIO and prefs["video_output"] == "auto":
        commands.append(download_command(*args, **options, convert=True))

    for attempt, command in enumerate(commands):
        config = proxy_config(command, prefs['proxy'])
        child = subprocess.Popen(command, stdin=subprocess.PIPE if config is not None else None,
                                 stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                 text=True, errors="replace", start_new_session=True)

        def stop(_signum, _frame):
            try:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
            except ProcessLookupError:
                pass
            sys.exit(130)

        signal.signal(signal.SIGTERM, stop)
        if config is not None:
            try:
                with child.stdin as pipe:
                    pipe.write(config)
            except BrokenPipeError:
                pass
        errors = []
        found = False
        emit("log", status=f"Starting {Path(command[0]).name} (attempt {attempt + 1})")
        for line in child.stdout:
            line = line.strip()
            if line.startswith("YTDL_FILE|"):
                path = json.loads(line.partition("|")[2])
                if isinstance(path, str) and Path(path).is_file():
                    found = True
                    emit("file", path=path)
            elif line.startswith("YTDL|"):
                percent = line.split("|", 2)[1].strip()
                emit("progress", status=f"Downloading · {percent}", percent=percent)
            elif line.startswith("[Merger]"):
                emit("progress", status="Merging video and audio…")
            elif line.startswith(("[VideoConvertor]", "[ExtractAudio]")):
                emit("progress", status="Converting…")
            elif line.startswith(("[MoveFiles]", "[VideoRemuxer]")):
                emit("progress", status="Saving…")
            elif line.startswith("ERROR:") or "][error]" in line.lower():
                errors.append(line)
                emit("log", status=line)
            elif line:
                emit("log", status=line)
        code = child.wait()
        if not code and found:
            return
        if attempt + 1 < len(commands) and any("Requested format is not available" in line for line in errors):
            emit("progress", status="Preparing MP4 conversion…")
            continue
        raise RuntimeError("\n".join(errors[-5:]) or ("Downloader returned no files." if not code
                                     else f"Downloader exited with code {code}."))


def main():
    try:
        action = sys.argv[1]
        if action == "yt-dlp":
            del sys.argv[1]
            import yt_dlp
            yt_dlp.main()
            return 0
        if action == "check-parth":
            from parth_dl import InstagramDownloader
            InstagramDownloader(quiet=True, rate_limit=True)
        elif action == "update-tools":
            from tools_update import update_tools
            update_tools(lambda status: emit("log", status=status), manual="--manual" in sys.argv[2:])
        elif action == "clean-tools":
            from tools_update import clean_old_kits
            emit("cleaned", count=clean_old_kits(sys.argv[2]))
        elif action == "tool-versions":
            from importlib.metadata import PackageNotFoundError, version
            root = Path(sys.argv[2])
            versions = {}
            for tool in ("yt-dlp", "ffmpeg", "ffprobe", "deno"):
                flag = "-version" if tool in ("ffmpeg", "ffprobe") else "--version"
                try:
                    result = subprocess.run([str(root / "bin" / tool), flag], check=True,
                                            capture_output=True, text=True, timeout=5)
                    line = result.stdout.splitlines()[0]
                    versions[tool] = line.split()[2] if flag == "-version" else line
                except (OSError, subprocess.SubprocessError, IndexError):
                    versions[tool] = "—"
            try:
                metadata = next((root / "engine").glob("**/parth_dl-*.dist-info/METADATA"), None)
                if metadata:
                    versions["parth-dl"] = next(line.split(": ", 1)[1]
                        for line in metadata.read_text(encoding="utf-8").splitlines() if line.startswith("Version: "))
                elif root == Path(sys.executable).parent.parent:
                    versions["parth-dl"] = version("parth-dl")
            except (OSError, PackageNotFoundError, StopIteration):
                pass
            emit("versions", versions=versions)
        elif action == "setup":
            install_missing(lambda tool, index, total: emit("progress", status=f"Installing {tool} ({index}/{total})…"))
            emit("capabilities", mode_keys=True, proxy_environment=True)
        elif action == "inspect":
            inspect(sys.argv[2])
        elif action == "download":
            download(json.loads(sys.argv[2]))
        else:
            raise ValueError("Unknown action.")
    except Exception as error:
        emit("error", status=str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
