"""Install missing macOS command-line tools in the current user's directory."""

import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import sys
from zipfile import ZipFile


BUNDLED = getattr(sys, "frozen", False)
BIN_DIR = (Path(sys.executable).parent.parent / "bin" if BUNDLED else
           Path.home() / "Library" / "Application Support" / "YTDL" / "bin")
TOOLS = ("yt-dlp", "ffmpeg", "ffprobe", "deno")


YTDLP_ENV = BIN_DIR.parent / "yt-dlp-python"
YTDLP_READY = YTDLP_ENV / ".ready-2026.10.26"


def tool_path(tool):
    if BUNDLED:
        return shutil.which(str(BIN_DIR / tool))
    if tool == "yt-dlp" and sys.platform == "darwin":
        executable = YTDLP_ENV / "bin" / tool
        python = YTDLP_ENV / "bin" / "python"
        if YTDLP_READY.is_file() and shutil.which(str(python)):
            return shutil.which(str(executable))
        return None
    return shutil.which(tool)


def install_python_ytdlp():
    framework = Path("/Library/Frameworks/Python.framework/Versions")
    versions = sorted(
        (int(path.name.split(".")[1]), path) for path in framework.glob("3.*")
        if re.fullmatch(r"3\.\d+", path.name) and int(path.name.split(".")[1]) >= 11
    )
    candidates = [path / "bin" / f"python{path.name}" for _, path in reversed(versions)]
    candidates.extend(Path(path) for name in ("python3", "python3.14", "python3.13",
                                              "python3.12", "python3.11")
                      if (path := shutil.which(name)))
    for candidate in dict.fromkeys(candidates):
        if not shutil.which(str(candidate)):
            continue
        probe = subprocess.run(
            [str(candidate), "-c", "import sys; sys.exit(sys.version_info < (3, 11))"],
            capture_output=True, timeout=15,
        )
        if probe.returncode == 0:
            break
    else:
        raise RuntimeError("Install Python 3.11+ from https://www.python.org/downloads/macos/ and retry.")

    subprocess.run([str(candidate), "-m", "venv", str(YTDLP_ENV)],
                   check=True, capture_output=True, text=True, timeout=120)
    python = YTDLP_ENV / "bin" / "python"
    subprocess.run(
        [str(python), "-m", "pip", "install", "yt-dlp[default]==2026.10.26"],
        check=True, capture_output=True, text=True, timeout=240,
    )
    subprocess.run([str(YTDLP_ENV / "bin" / "yt-dlp"), "--version"],
                   check=True, capture_output=True, text=True, timeout=30)
    YTDLP_READY.touch()


def download(url, destination):
    subprocess.run(
        ["/usr/bin/curl", "--disable", "--fail", "--silent", "--show-error",
         "--location", "--proto", "=https", "--proto-redir", "=https",
         "--connect-timeout", "15", "--max-time", "180",
         "--output", str(destination), url],
        check=True, capture_output=True, text=True,
    )


def install_missing(report):
    architecture = platform.machine()
    ffmpeg_arch, deno_arch = {
        "arm64": ("arm64", "aarch64"), "x86_64": ("x64", "x86_64")
    }[architecture]
    sources = {
        "ffmpeg": ("eugeneware/ffmpeg-static", "tags/b6.1.1", f"ffmpeg-darwin-{ffmpeg_arch}"),
        "ffprobe": ("eugeneware/ffmpeg-static", "tags/b6.1.1", f"ffprobe-darwin-{ffmpeg_arch}"),
        "deno": ("denoland/deno", "tags/v2.9.8", f"deno-{deno_arch}-apple-darwin.zip"),
    }
    missing = [tool for tool in TOOLS if not tool_path(tool)]
    if not missing:
        return
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    releases = {}
    with tempfile.TemporaryDirectory(prefix=".install-", dir=BIN_DIR) as directory:
        staging = Path(directory)
        for index, tool in enumerate(missing, 1):
            if tool_path(tool):
                continue
            report(tool, index, len(missing))
            if tool == "yt-dlp":
                install_python_ytdlp()
                continue
            repo, release, filename = sources[tool]
            if (repo, release) not in releases:
                metadata = staging / "release.json"
                download(f"https://api.github.com/repos/{repo}/releases/{release}", metadata)
                releases[repo, release] = json.loads(metadata.read_text(encoding="utf-8"))
            asset = next((item for item in releases[repo, release]["assets"]
                          if item["name"] == filename), {})
            digest = asset.get("digest") or ""
            url = asset.get("browser_download_url", "")
            if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest) or not url.startswith(
                f"https://github.com/{repo}/releases/download/"
            ):
                raise ValueError(f"{tool}: GitHub release asset or SHA-256 digest unavailable")
            downloaded = staging / filename
            download(url, downloaded)
            checksum = hashlib.sha256()
            with downloaded.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    checksum.update(chunk)
            actual = checksum.hexdigest()
            if digest != f"sha256:{actual}":
                raise ValueError(f"{tool}: SHA-256 mismatch")
            executable = downloaded
            if tool == "deno":
                executable = staging / tool
                with ZipFile(downloaded) as archive, archive.open("deno") as source:
                    with executable.open("wb") as output:
                        shutil.copyfileobj(source, output)
            executable.chmod(0o755)
            version_arg = "-version" if tool in ("ffmpeg", "ffprobe") else "--version"
            subprocess.run([str(executable), version_arg], check=True, capture_output=True,
                           text=True, timeout=30)
            executable.replace(BIN_DIR / tool)
