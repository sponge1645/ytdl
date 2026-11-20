#!/bin/bash
set -euo pipefail

app="$1"
work="$2"
safari_dir="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"

if ! xcodebuild -version >/dev/null 2>&1; then
    echo "The Safari extension build requires full Xcode. Select it with xcode-select or DEVELOPER_DIR." >&2
    exit 1
fi

packager=safari-web-extension-packager
if ! xcrun --find "$packager" >/dev/null 2>&1; then
    packager=safari-web-extension-converter
fi

mkdir -p "$work/project" "$work/web"
cp "$safari_dir/manifest.json" "$safari_dir/youtube.js" "$safari_dir/youtube.css" "$work/web/"
cp -R "$safari_dir/_locales" "$work/web/"
xcrun "$packager" "$work/web" --macos-only --swift \
    --project-location "$work/project" --app-name "YTDL Safari" \
    --bundle-identifier "$bundle_id" --no-prompt --no-open

project="$(find "$work/project" -name '*.xcodeproj' -type d -print -quit)"
test -n "$project"
xcodebuild -project "$project" -alltargets -configuration Release -sdk macosx \
    CONFIGURATION_BUILD_DIR="$work/products" CODE_SIGNING_ALLOWED=NO \
    ARCHS="x86_64 arm64" ONLY_ACTIVE_ARCH=NO build

extension="$(find "$work/products" -name '*.appex' -type d -prune -print -quit)"
test -n "$extension"
plugins="$app/Contents/PlugIns"
mkdir -p "$plugins"
embedded="$plugins/${extension##*/}"
ditto "$extension" "$embedded"

plist="$embedded/Contents/Info.plist"
extension_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")"
[[ "$extension_id" == "$bundle_id".* ]]
test "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$plist")" = com.apple.Safari.web-extension
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
xcrun lipo "$embedded/Contents/MacOS/$executable" -verify_arch x86_64 arm64
test -s "$embedded/Contents/Resources/manifest.json"
codesign --force --sign - --entitlements "$safari_dir/build/extension.entitlements" "$embedded"
