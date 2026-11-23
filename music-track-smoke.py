"""Run one Amazon Music FLAC job through the bundled Mornye desktop ABI."""
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
import subprocess
import tempfile
from urllib.parse import parse_qs, urlsplit
from uuid import uuid4


CALLBACK = ctypes.CFUNCTYPE(None, ctypes.c_uint64, ctypes.c_int32, ctypes.c_void_p, ctypes.c_size_t)
PACKAGE_SHA256 = "5177325613ad65b9475aa02e8befb651b68a324d465f04869f2906f5f59044ec"


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


def verify(engine):
    pending = engine.call("getExtensionPendingAuth", {"extension_id": "amazon"})
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


def run(args, home):
    library = args.app / "Contents/Frameworks/libmornye_desktop.dylib"
    package = args.package.resolve()
    if hashlib.sha256(package.read_bytes()).hexdigest() != PACKAGE_SHA256:
        raise RuntimeError("The Amazon extension checksum did not match the tested release.")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    engine = Engine(library.resolve(), home)
    engine.call("initExtensionSystem", {
        "extensions_dir": str(home / "extensions"),
        "data_dir": str(home / "data"),
        "master_key": base64.b64encode(secrets.token_bytes(32)).decode(),
        "allowed_directories": [str(output)],
    })
    installed = engine.call("loadExtensionFromPath", {"file_path": str(package)})
    if isinstance(installed, dict) and installed.get("success") is False:
        raise RuntimeError("The engine could not load the Amazon extension.")
    request = {
        "contract_version": 1, "service": "amazon", "download_provider": "amazon",
        "provider_track_id": args.track_id, "track_name": args.title,
        "artist_name": args.artist, "output_dir": str(output), "output_ext": "flac",
        "quality": "best", "item_id": str(uuid4()), "use_extensions": True,
        "use_fallback": False, "embed_metadata": True,
    }
    result = engine.call("downloadByStrategy", json.dumps(request))
    if isinstance(result, dict) and result.get("error_type") == "verification_required":
        verify(engine)
        result = engine.call("downloadByStrategy", json.dumps(request))
    if not isinstance(result, dict) or result.get("success") is not True:
        reason = result.get("error_type", "unknown") if isinstance(result, dict) else "invalid response"
        raise RuntimeError(f"Amazon Music did not complete the test download ({reason}).")
    for path in output.rglob("*.flac"):
        with path.open("rb") as audio:
            if audio.read(4) == b"fLaC":
                print(f"Saved FLAC: {path}")
                return
    raise RuntimeError("The engine reported success without a readable FLAC file.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("package", type=Path)
    parser.add_argument("track_id", help="Amazon Music track ID")
    parser.add_argument("title")
    parser.add_argument("artist")
    parser.add_argument("output", type=Path, help="New directory for the test download")
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Choose a new output directory so the test cannot match an old file.")
    try:
        with tempfile.TemporaryDirectory(prefix="ytdl-music-") as home:
            run(args, Path(home))
    except (OSError, RuntimeError, ValueError) as error:
        parser.exit(1, f"{error}\n")
