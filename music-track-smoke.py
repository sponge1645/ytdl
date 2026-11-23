"""Run one FLAC job through the bundled Mornye desktop ABI."""
import argparse
import base64
import ctypes
import getpass
import hashlib
import itertools
import json
from pathlib import Path
import queue
import secrets
import shutil
import re
import subprocess
import tempfile
from urllib.parse import parse_qs, urlsplit
from urllib.request import urlopen
from uuid import uuid4


CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_uint64, ctypes.c_int32, ctypes.c_void_p, ctypes.c_size_t)
EXTENSION_REVISION = "a4c27605dfca6e41aae1efe72db6d22d9ca69bfd"
PACKAGES = {
    "tidal-web": "fcd7a0ca4dda3dacd688c6962db218f89dd165d5449c640e71a0b1bf24847cce",
    "qobuz-web": "c29bdf9f816e5eaab5956552f7236be9b18e89255ce2c39b7681d24f358cde97",
    "deezer": "86f3efb1068c2cc07fe197de623962e6d35c171669a732c72cb4c6be77cf43d2",
    "amzn": "5177325613ad65b9475aa02e8befb651b68a324d465f04869f2906f5f59044ec",
    "spotify-web": "8ed483f6c451a3af08303b833457de3fa72d8ec8aec1d80bb5f4594c2a303640",
    "apple-music": "851a498c3030def53dc98af03aff772974f1338f1964ffa367c07cce8c73af07",
}

DOWNLOADERS = {
    "amazon": ("amzn", "best", "Amazon Music"),
    "tidal-web": ("tidal-web", "HI_RES_LOSSLESS", "Tidal"),
    "qobuz-web": ("qobuz-web", "HI_RES_LOSSLESS", "Qobuz"),
    "deezer": ("deezer", "flac", "Deezer"),
}


class Engine:
    def __init__(self, library, home):
        self.lib = ctypes.CDLL(str(library))
        self.lib.mornye_free.argtypes = [ctypes.c_void_p, ctypes.c_size_t]
        self.lib.mornye_init.argtypes = [CALLBACK, ctypes.c_char_p, ctypes.c_size_t]
        self.lib.mornye_call.argtypes = [
            ctypes.c_uint64, ctypes.c_char_p, ctypes.c_char_p,
            ctypes.c_size_t, ctypes.c_void_p, ctypes.c_size_t,
        ]
        self.lib.mornye_cancel.argtypes = [ctypes.c_uint64]
        for name in ("init", "call", "cancel", "free"):
            getattr(self.lib, "mornye_" + name).restype = None
        self.replies = queue.Queue()
        self.ids = itertools.count(1)
        self.callback = CALLBACK(self.receive)
        config = json.dumps({
            "app_support_dir": str(home),
            "documents_dir": str(home),
            "temp_dir": str(home),
            "app_version": "5.3.0",
        }).encode()
        self.lib.mornye_init(self.callback, config, len(config))

    def receive(self, call_id, kind, data, length):
        try:
            if call_id and kind in (0, 1, 2):
                self.replies.put((call_id, kind, ctypes.string_at(data, length)))
        finally:
            if data:
                self.lib.mornye_free(data, length)

    def call(self, method, args):
        call_id = next(self.ids)
        payload = json.dumps(args).encode()
        self.lib.mornye_call(call_id, method.encode(), payload, len(payload), None, 0)
        try:
            reply_id, kind, data = self.replies.get(timeout=180)
        except queue.Empty:
            self.lib.mornye_cancel(call_id)
            raise RuntimeError(f"{method} timed out.") from None
        if reply_id != call_id or kind != 0:
            raise RuntimeError(f"The engine rejected {method} (callback kind {kind}).")
        result = json.loads(data)
        if isinstance(result, str):
            try:
                return json.loads(result)
            except json.JSONDecodeError:
                return result
        return result


def verify(engine, service):
    pending = engine.call("getExtensionPendingAuth", {"extension_id": service})
    url = pending.get("auth_url", "") if isinstance(pending, dict) else ""
    challenge = urlsplit(url)
    if (challenge.scheme, challenge.netloc, challenge.path) != (
        "https", "api.zarz.moe", "/v2/challenge",
    ):
        raise RuntimeError("The engine did not provide an expected verification page.")
    expected = parse_qs(urlsplit(parse_qs(challenge.query).get("cb", [""])[0]).query).get("state")
    if not expected or len(expected) != 1:
        raise RuntimeError("The verification request did not contain a session state.")
    subprocess.run(["open", url], check=True)
    callback = getpass.getpass(
        "Complete verification in the browser, then paste the final mornye:// return URL here: "
    ).strip()
    parsed = urlsplit(callback)
    values = parse_qs(parsed.query)
    if ((parsed.scheme, parsed.netloc) != ("mornye", "session-grant")
            or values.get("state") != expected or len(values.get("grant", [])) != 1):
        raise RuntimeError("The browser response did not match the active verification.")
    if engine.call("queueExtensionCallbackUrl", {"url": callback}) is not True:
        raise RuntimeError("The engine rejected the browser return URL.")
    engine.call("processPendingExtensionCallbacks", {})


def install_package(engine, home, name):
    base = "https://raw.githubusercontent.com/mornyeapp/Mornye-Extension"
    url = f"{base}/{EXTENSION_REVISION}/extensions/{name}.sflx"
    with urlopen(url, timeout=20) as response:
        data = response.read(4 * 1024 * 1024 + 1)
    if hashlib.sha256(data).hexdigest() != PACKAGES[name]:
        raise RuntimeError(f"The {name} extension failed checksum verification.")
    package = home / f"{name}.sflx"
    package.write_bytes(data)
    result = engine.call("loadExtensionFromPath", {"file_path": str(package)})
    if isinstance(result, dict) and result.get("success") is False:
        raise RuntimeError(f"The engine could not load {name}.")


def metadata_provider(url):
    parts = urlsplit(url)
    if parts.scheme != "https":
        raise ValueError("Paste an HTTPS music track link.")
    if parts.netloc == "open.spotify.com":
        return "spotify-web"
    if parts.netloc == "music.apple.com":
        return "apple-music"
    if parts.netloc in {"tidal.com", "www.tidal.com", "listen.tidal.com"}:
        return "tidal-web"
    if parts.netloc in {"qobuz.com", "www.qobuz.com", "play.qobuz.com", "open.qobuz.com"}:
        return "qobuz-web"
    if parts.netloc in {"deezer.com", "www.deezer.com", "link.deezer.com", "deezer.page.link"}:
        return "deezer"
    if parts.netloc in {"music.amazon.com", "music.amazon.co.uk", "music.amazon.de",
                       "music.amazon.co.jp", "music.amazon.fr", "music.amazon.it",
                       "music.amazon.es", "music.amazon.in", "music.amazon.com.br",
                       "music.amazon.com.mx", "music.amazon.com.au", "music.amazon.co"}:
        return "amzn"
    raise ValueError("This music catalog is not supported by the preview.")


def resolve_track(engine, url):
    result = engine.call("handleURLWithExtension", {"url": url})
    track = result.get("track") if isinstance(result, dict) and result.get("type") == "track" else None
    if not isinstance(track, dict) or not track.get("name") or not track.get("artists"):
        raise RuntimeError("Could not read one track from this link. Use a track link, not an album or playlist.")
    return track


def ffmpeg_path():
    root = Path.home() / "Library/Application Support/YTDL/tool-kits-v1"
    current = root / "current"
    version = current.read_text().strip() if current.is_file() else ""
    if version.isascii() and version.isdecimal():
        bundled = root / version / "bin/ffmpeg"
        if bundled.is_file():
            return str(bundled)
    executable = shutil.which("ffmpeg")
    if executable:
        return executable
    raise RuntimeError("FFmpeg is missing. Open YTDL to install the tools or put FFmpeg on PATH.")


def finalize_flac(path, descriptor):
    if descriptor.get("strategy") != "ffmpeg.mov_key":
        raise RuntimeError("Amazon returned an unsupported finalization type.")
    key = descriptor.get("key", "")
    if not isinstance(key, str):
        raise RuntimeError("Amazon did not return a usable finalization key.")
    key = key.strip().removeprefix("0x")
    if not re.fullmatch(r"[0-9a-fA-F]{32}", key):
        raise RuntimeError("Amazon did not return a usable finalization key.")
    ffmpeg = ffmpeg_path()
    destination = path.with_suffix(".flac")
    with tempfile.TemporaryDirectory(prefix=".ytdl-finalize-", dir=path.parent) as work:
        staged = Path(work) / "audio.flac"
        commands = [
            [ffmpeg, "-nostdin", "-v", "error", "-decryption_key", key, "-f", "mov",
             "-i", str(path), "-map", "0:a:0", "-c:a", "copy", "-f", "flac", str(staged)],
            [ffmpeg, "-nostdin", "-v", "error", "-xerror", "-i", str(staged),
             "-map", "0:a:0", "-f", "null", "-"],
        ]
        for command in commands:
            completed = subprocess.run(command, capture_output=True, timeout=120)
            if completed.returncode:
                raise RuntimeError("FFmpeg could not finalize or decode the FLAC. The original was kept.")
        if destination == path:
            staged.replace(destination)
        else:
            destination.hardlink_to(staged)
    return destination


def run(args, home):
    provider = metadata_provider(args.url)
    library = args.app / "Contents/Frameworks/libmornye_desktop.dylib"
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    engine = Engine(library.resolve(), home)
    engine.call("initExtensionSystem", {
        "extensions_dir": str(home / "extensions"),
        "data_dir": str(home / "data"),
        "master_key": base64.b64encode(secrets.token_bytes(32)).decode(),
        "allowed_directories": [str(output)],
    })
    engine.call("setDownloadDirectory", {"path": str(output)})
    install_package(engine, home, provider)
    service = args.source or ("amazon" if provider in {"amzn", "spotify-web", "apple-music"} else provider)
    package, quality, label = DOWNLOADERS[service]
    if package != provider:
        install_package(engine, home, package)
    track = resolve_track(engine, args.url)
    print(f"Searching {label} for {track['artists']} — {track['name']}", flush=True)
    stem = re.sub(r'[<>:"/\\|?*\x00-\x1f\x7f]', " ", f"{track['artists']} - {track['name']}")
    stem = " ".join(stem.split()).strip(". ")
    stem = stem.encode("utf-8")[:200].decode("utf-8", errors="ignore").rstrip(". ") or "Track"
    request = {
        "contract_version": 1, "service": service, "download_provider": service,
        "track_name": track["name"], "artist_name": track["artists"],
        "isrc": track.get("isrc") or "", "duration_ms": track.get("duration_ms") or 0,
        "album_name": track.get("album_name") or "",
        "output_dir": str(output), "output_path": str(output / f"{stem}.flac"),
        "output_ext": ".flac",
        "quality": quality, "item_id": str(uuid4()), "use_extensions": True,
        "use_fallback": False, "embed_metadata": True,
    }
    result = engine.call("downloadByStrategy", json.dumps(request))
    if isinstance(result, dict) and result.get("error_type") == "verification_required":
        verify(engine, service)
        result = engine.call("downloadByStrategy", json.dumps(request))
    if not isinstance(result, dict) or result.get("success") is not True:
        reason = result.get("error_type", "unknown") if isinstance(result, dict) else "invalid response"
        raise RuntimeError(f"{label} did not complete the test download ({reason}).")
    reported = result.get("file_path")
    actual = result.get("actual_extension") or "unknown"
    if not isinstance(reported, str) or not reported:
        raise RuntimeError(f"The engine reported success without a file path (format: {actual}).")
    path = Path(reported)
    if not path.is_absolute():
        path = output / path
    path = path.resolve()
    if output not in path.parents or not path.is_file():
        raise RuntimeError(f"The file reported by the engine is unavailable: {path} (format: {actual}).")
    descriptor = result.get("decryption")
    if isinstance(descriptor, dict) and descriptor.get("key"):
        path = finalize_flac(path, descriptor)
    with path.open("rb") as audio:
        header = audio.read(10)
        if header.startswith(b"ID3") and len(header) == 10 and all(n < 128 for n in header[6:10]):
            size = 0
            for byte in header[6:10]:
                size = (size << 7) | byte
            audio.seek(10 + size + (10 if header[3] == 4 and header[5] & 16 else 0))
            header = audio.read(4)
    if not header.startswith(b"fLaC"):
        raise RuntimeError(f"{label} returned a file without a FLAC header (format: {actual}): {path}")
    print(f"Saved FLAC: {path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("url", help="Single-track music link")
    parser.add_argument("--source", choices=DOWNLOADERS, help="Override the audio source")
    parser.add_argument("output", type=Path, help="New directory for the test download")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Choose a new output directory so the test cannot match an old file.")
    try:
        with tempfile.TemporaryDirectory(prefix="ytdl-music-") as home:
            run(args, Path(home))
    except subprocess.TimeoutExpired:
        parser.exit(1, "FFmpeg finalization timed out. The original was kept.\n")
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"{error}\n")
