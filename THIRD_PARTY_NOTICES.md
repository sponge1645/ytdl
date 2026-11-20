# Third-party notices

The repository's MIT license covers the original YTDL code. Components distributed in the separately downloadable engine kit retain their own licenses.

| Component | License and source |
| --- | --- |
| yt-dlp | The core package on PyPI is under the [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE). The build installs `yt-dlp[default]`, whose additional packages carry their own licenses. See [yt-dlp's licensing notes](https://github.com/yt-dlp/yt-dlp#licensing). |
| parth-dl 1.2.0 | MIT, by Saksham Pathak (Parthmax). See the [package and its source links](https://pypi.org/project/parth-dl/1.2.0/). |
| FFmpeg and FFprobe | Distributed as separate executables from [ffmpeg-static b6.1.1](https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.1.1). FFmpeg's terms depend on the build configuration. See [FFmpeg licensing](https://ffmpeg.org/legal.html) and [FFmpeg source](https://github.com/FFmpeg/FFmpeg/tree/n6.1.1). |
| Deno 2.9.8 | [MIT](https://github.com/denoland/deno/blob/v2.9.8/LICENSE.md), with additional licenses for components incorporated in the [upstream binaries](https://github.com/denoland/deno/releases/tag/v2.9.8). |
| CPython | The engine includes a Python runtime under the [Python Software Foundation license and associated notices](https://docs.python.org/3/license.html). |
| PyInstaller | The engine is packaged with PyInstaller. See its [GPL exception and licensing terms](https://pyinstaller.org/en/stable/license.html). |

This inventory describes the build inputs. For redistribution, review the exact binaries and resolved Python dependencies in the kit and provide their applicable notices and corresponding source where required.
