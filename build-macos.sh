#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "Build the native app on macOS with Command Line Tools." >&2
    exit 1
fi

version="$(cat VERSION)"
build_number="${YTDL_BUILD_NUMBER:-5}"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ && "$build_number" =~ ^[0-9]+$ ]]

arch="$(uname -m)"
minimum=10.15
if [[ "$arch" == arm64 ]]; then minimum=11.0; fi
variant="${1:---universal}"
case "$variant" in
    --engine-kit)
        output="$PWD/dist/engine-kit/YouTube Downloader.app"
        ;;
    --universal)
        : "${YTDL_TOOLS_PUBLIC_KEY:?Set YTDL_TOOLS_PUBLIC_KEY to build the Universal app}"
        minimum=10.15
        output="$PWD/dist/universal/YouTube Downloader.app"
        if [[ -n "${YTDL_MUSIC_ENGINE_LIBRARY:-}" ]]; then
            minimum=11.0
        fi
        ;;
    *) echo "Usage: $0 [--universal|--engine-kit]" >&2; exit 2 ;;
esac
mkdir -p "$(dirname "$output")"
staging="$(mktemp -d "$PWD/dist/.native-build.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
app="$staging/YouTube Downloader.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
compile_app() {
    xcrun --sdk macosx swiftc -O -target "$1" \
        -framework AppKit -framework UserNotifications -framework Security native/*.swift -o "$2"
}
executable="$app/Contents/MacOS/YouTubeDownloader"
if [[ "$variant" == --universal ]]; then
    compile_app "x86_64-apple-macos$minimum" "$staging/intel"
    compile_app arm64-apple-macos11.0 "$staging/arm"
    xcrun lipo -create "$staging/intel" "$staging/arm" -output "$executable"
    xcrun lipo "$executable" -verify_arch x86_64 arm64
else
    compile_app "$arch-apple-macos$minimum" "$executable"
fi
resources="$app/Contents/Resources"
cp LICENSE THIRD_PARTY_NOTICES.md "$resources/"
if [[ -n "${YTDL_TOOLS_PUBLIC_KEY:-}" ]]; then
    printf '%s\n' "$YTDL_TOOLS_PUBLIC_KEY" > "$resources/tools-update-public.pem"
    /usr/bin/openssl pkey -pubin -in "$resources/tools-update-public.pem" -noout
fi
if [[ "$variant" == --universal ]]; then
    cp native/bootstrap-tools.sh "$resources/"
else
    python="${YTDL_BUILD_PYTHON:-python3}"
    "$python" -c 'import sys; sys.exit(sys.version_info < (3, 11))' || {
        echo "The build machine needs Python 3.11 or newer." >&2
        exit 1
    }
    "$python" -m venv "$staging/venv"
    builder="$staging/venv/bin/python"
    "$builder" -m pip install --disable-pip-version-check \
        "pyinstaller==6.21.0" "${YTDL_YTDLP_REQUIREMENT:-yt-dlp[default]==2026.10.26}" \
        "${YTDL_PARTH_REQUIREMENT:-parth-dl==1.2.0}"
    "$builder" -m PyInstaller --noconfirm --onedir --name ytdl-engine \
        --distpath "$staging/engine-dist" --workpath "$staging/engine-build" --specpath "$staging" \
        --paths "$PWD" --paths "$PWD/native" --exclude-module tkinter --collect-submodules yt_dlp --collect-data yt_dlp --collect-all yt_dlp_ejs \
        --copy-metadata parth-dl native/backend.py
    mv "$staging/engine-dist/ytdl-engine" "$resources/engine"
    mkdir "$resources/bin"
    for tool in yt-dlp; do
        cat > "$resources/bin/$tool" <<'TOOL'
#!/bin/sh
exec "${0%/*}/../engine/ytdl-engine" "${0##*/}" "$@"
TOOL
        chmod +x "$resources/bin/$tool"
        "$resources/bin/$tool" --version
    done
    "$resources/engine/ytdl-engine" check-parth
    "$resources/engine/ytdl-engine" setup
    for tool in ffmpeg ffprobe deno; do
        test -x "$resources/bin/$tool"
    done
fi
if [[ -f /System/Library/Sounds/Basso.aiff ]]; then
    cp /System/Library/Sounds/Basso.aiff "$resources/Basso.aiff"
fi
iconset="$staging/AppIcon.iconset"
mkdir "$iconset"
# Trim excess transparent padding before rendering the icon at each size.
icon_source="$staging/AppIcon.png"
sips --cropToHeightWidth 470 470 app-icon.png --out "$icon_source" >/dev/null
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>YouTubeDownloader</string>
  <key>CFBundleIdentifier</key><string>com.sponge1645.ytdl.native</string>
  <key>CFBundleName</key><string>YouTube Downloader</string>
  <key>CFBundleDisplayName</key><string>YouTube Downloader</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundleVersion</key><string>$build_number</string>
  <key>LSMinimumSystemVersion</key><string>$minimum</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleURLTypes</key>
  <array><dict>
    <key>CFBundleURLName</key><string>com.sponge1645.ytdl.youtube</string>
    <key>CFBundleURLSchemes</key><array><string>ytdl</string></array>
  </dict></array>
</dict></plist>
PLIST
if [[ -n "${YTDL_MUSIC_ENGINE_LIBRARY:-}" && "$variant" == --universal ]]; then
    xcrun lipo "$YTDL_MUSIC_ENGINE_LIBRARY" -verify_arch x86_64 arm64
    cp music-track-smoke.py "$resources/"
    notice_dir="$resources/Mornye"
    mkdir -p "$notice_dir"
    if [[ -n "${YTDL_MUSIC_ENGINE_SOURCE:-}" ]]; then
        cp "$YTDL_MUSIC_ENGINE_SOURCE/"{LICENSE,COPYING,NOTICE} "$notice_dir/"
    fi
    cat > "$notice_dir/Source.txt" <<'NOTICE'
YouTube Downloader uses the separately loaded Mornye desktop engine (LGPL).
Source and build instructions:
https://github.com/mornyeapp/Mornye/tree/c4a1c7b812eb135d6e1a295b6b25e11abbd72a7e
NOTICE
    plist="$app/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:1 dict' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:1:CFBundleURLName string com.sponge1645.ytdl.music' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:1:CFBundleURLSchemes array' "$plist"
    /usr/libexec/PlistBuddy -c 'Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string mornye' "$plist"
    mkdir -p "$app/Contents/Frameworks"
    cp "$YTDL_MUSIC_ENGINE_LIBRARY" "$app/Contents/Frameworks/libmornye_desktop.dylib"
    codesign --force --sign - "$app/Contents/Frameworks/libmornye_desktop.dylib"
fi
if [[ "$variant" == --universal && "${YTDL_BUILD_SAFARI:-0}" == 1 ]]; then
    bash safari/build/embed.sh "$app" "$staging/safari"
fi
if [[ "$variant" == --engine-kit ]]; then
    codesign --force --deep --sign - "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify --deep --strict "$app"
if [[ -e "$output" ]]; then
    mv "$output" "$staging/previous.app"
fi
if ! mv "$app" "$output"; then
    if [[ -e "$staging/previous.app" ]]; then
        mv "$staging/previous.app" "$output" || {
            trap - EXIT
            echo "Previous build is available at $staging/previous.app" >&2
        }
    fi
    exit 1
fi
# Refresh this bundle's Launch Services entry without resetting other apps.
lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$lsregister" && -z "${CI:-}" ]]; then
    "$lsregister" -f "$output" || echo "Launch Services registration failed; open the app from Finder." >&2
fi
du -sh "$output"
if [[ "$variant" == --engine-kit ]]; then
    du -sh "$output/Contents/Resources/engine" "$output/Contents/Resources/bin/"*
fi
echo "Built $output (version $version, macOS $minimum+)"
