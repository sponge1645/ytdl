"""Install missing macOS command-line tools in the current user's directory."""

import hashlib
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import time
import sys
from zipfile import ZipFile


BUNDLED = getattr(sys, "frozen", False)
BIN_DIR = (Path(sys.executable).parent.parent / "bin" if BUNDLED else
           Path.home() / "Library" / "Application Support" / "YTDL" / "bin")
TOOLS = ("yt-dlp", "ffmpeg", "ffprobe", "deno")

# Release assets and SHA-256 digests from the upstream GitHub releases.
TOOL_ASSETS = {
    "arm64": {
        "ffmpeg": (
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-arm64",
            "a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584",
        ),
        "ffprobe": (
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-arm64",
            "bb2db6f5d8cef919da12fbf592119a987202a8c060a886f3cab091f9cab90b64",
        ),
        "deno": (
            "https://github.com/denoland/deno/releases/download/v2.9.8/deno-aarch64-apple-darwin.zip",
            "9f0bf660393da2eaff044cdc7444cb08c73f235849b61d224d825a194ce7c98e",
        ),
    },
    "x86_64": {
        "ffmpeg": (
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-darwin-x64",
            "ebdddc936f61e14049a2d4b549a412b8a40deeff6540e58a9f2a2da9e6b18894",
        ),
        "ffprobe": (
            "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffprobe-darwin-x64",
            "fa3add0ce901f7241abe0dfc0155d958fc834aca3f8ce61f87cc712ae669c1e0",
        ),
        "deno": (
            "https://github.com/denoland/deno/releases/download/v2.9.8/deno-x86_64-apple-darwin.zip",
            "4b2f5edd2639b7470f034238b321d7002d8dfb4726d8558f52c17afac370eb2c",
        ),
    },
}


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
    arguments = [
        "/usr/bin/curl", "--disable", "--fail", "--silent", "--show-error",
        "--location", "--proto", "=https", "--proto-redir", "=https",
        "--connect-timeout", "15", "--max-time", "180",
        "--output", str(destination), url,
    ]
    for attempt in range(3):
        try:
            subprocess.run(arguments, check=True, capture_output=True, text=True)
            return
        except subprocess.CalledProcessError as error:
            if error.returncode not in {6, 7, 18, 28, 35, 52, 55, 56} or attempt == 2:
                raise
            time.sleep(attempt + 1)


def install_missing(report):
    sources = TOOL_ASSETS[platform.machine()]
    missing = [tool for tool in TOOLS if not tool_path(tool)]
    if not missing:
        return
    BIN_DIR.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".install-", dir=BIN_DIR) as directory:
        staging = Path(directory)
        for index, tool in enumerate(missing, 1):
            if tool_path(tool):
                continue
            report(tool, index, len(missing))
            if tool == "yt-dlp":
                install_python_ytdlp()
                continue
            url, digest = sources[tool]
            downloaded = staging / url.rsplit("/", 1)[-1]
            download(url, downloaded)
            checksum = hashlib.sha256()
            with downloaded.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    checksum.update(chunk)
            actual = checksum.hexdigest()
            if digest != actual:
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
