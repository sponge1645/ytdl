"""Install signed engine kits for use on the next app launch."""
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

from dependencies import download

RELEASE = "https://github.com/sponge1645/ytdl/releases/download/tools-v1"
CHECK_INTERVAL = 86400


def cache_root():
    return Path.home() / "Library/Application Support/YTDL/tool-kits-v1" / platform.machine()


def clean_old_kits(active):
    import shutil

    root = cache_root()
    if not root.is_dir():
        return 0
    with (root / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        pointer = root / "current"
        current = pointer.read_text(encoding="ascii").strip() if pointer.is_file() else ""
        candidates = sorted(
            (entry for entry in root.iterdir() if re.fullmatch(r"[1-9][0-9]{0,15}", entry.name)
             and entry.is_dir() and not entry.is_symlink() and entry.name not in {active, current}),
            key=lambda entry: int(entry.name), reverse=True
        )
        for entry in candidates[1:]:
            shutil.rmtree(entry)
        return max(0, len(candidates) - 1)


def update_tools(report, *, manual=False):
    key = Path(sys.executable).parent.parent / "tools-update-public.pem"
    if not key.is_file():
        if manual:
            raise RuntimeError("Update channel is not configured.")
        return
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        return
    root = cache_root()
    root.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (root / "lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            if manual:
                raise RuntimeError("Another tools operation is in progress.") from None
            return
        check = root / "checked"
        if not manual and check.exists() and time.time() - check.stat().st_mtime < CHECK_INTERVAL:
            return
        attempt = root / "attempted"
        if not manual and attempt.exists() and time.time() - attempt.stat().st_mtime < 900:
            return
        attempt.touch()
        with tempfile.TemporaryDirectory(prefix=".staging-", dir=root) as directory:
            work = Path(directory)
            asset = f"tools-v1-{architecture}"
            manifest = work / "manifest"
            signature = work / "manifest.sig"
            download(f"{RELEASE}/{asset}.manifest", manifest)
            download(f"{RELEASE}/{asset}.sig", signature)
            subprocess.run(["/usr/bin/openssl", "dgst", "-sha256", "-verify", str(key),
                            "-signature", str(signature), str(manifest)],
                           check=True, capture_output=True, timeout=10)
            version, digest = manifest.read_text(encoding="ascii").split()
            if not re.fullmatch(r"[1-9][0-9]{0,15}", version) or not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError("Invalid signed tools manifest.")
            pointer = root / "current"
            if pointer.is_file():
                current = pointer.read_text(encoding="ascii").strip()
                if current.isdecimal() and int(current) >= int(version):
                    check.touch()
                    if manual:
                        report("No newer tools package is available.")
                    return
            report("Downloading updated tools…")
            archive = work / "tools.zip"
            download(f"{RELEASE}/{asset}.zip", archive)
            with archive.open("rb") as source:
                actual = hashlib.file_digest(source, "sha256").hexdigest()
            if actual != digest:
                raise ValueError("Tools archive does not match its signed manifest.")
            kit = work / "kit"
            subprocess.run(["/usr/bin/ditto", "-x", "-k", str(archive), str(kit)],
                           check=True, capture_output=True, timeout=90)
            if (kit / "bin/gallery-dl").exists():
                raise ValueError("The available engine kit predates this app build.")
            commands = [
                ("engine/ytdl-engine", "check-parth"),
                ("bin/yt-dlp", "--version"),
                ("bin/ffmpeg", "-version"), ("bin/ffprobe", "-version"),
                ("bin/deno", "--version"),
            ]
            for executable, flag in commands:
                subprocess.run([str(kit / executable), flag], check=True,
                               capture_output=True, timeout=20)
            installed = root / version
            if installed.exists():
                raise RuntimeError("This tools version is already staged.")
            kit.rename(installed)
            try:
                pending = work / "current"
                pending.write_text(version + "\n", encoding="ascii")
                os.replace(pending, pointer)
            except OSError:
                installed.rename(kit)
                raise
            check.touch()
            report("Tools updated. The new versions will be used after restarting the app.")
