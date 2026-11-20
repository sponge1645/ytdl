#!/bin/bash
# Bootstrap an engine kit with utilities already included in macOS.
set -Eeuo pipefail
export LC_ALL=C

key="$1"
root="$2"
arch="$3"
mode="$4"
url="https://github.com/sponge1645/ytdl/releases/download/tools-v1/tools-v1-$arch"
stage="Preparing installation"
trap 'code=$?; printf "%s failed (exit %s).\n" "$stage" "$code" >&2' ERR
[[ -s "$key" ]] || { echo "The bundled update key is missing."; exit 1; }
work="$(mktemp -d "$root/.bootstrap.XXXXXX")"
trap 'rm -rf "$work"' EXIT

download() {
    /usr/bin/curl --disable --fail --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time "$1" --output "$2" "${@:3}"
}

stage="Downloading the signed manifest"
echo "STEP 1"
download 30 "$work/manifest" --silent --show-error --max-filesize 4096 "$url.manifest"
download 30 "$work/signature" --silent --show-error --max-filesize 4096 "$url.sig"
stage="Verifying the manifest signature"
/usr/bin/openssl dgst -sha256 -verify "$key" -signature "$work/signature" "$work/manifest" >/dev/null
stage="Reading the signed manifest"
read -r version digest extra < "$work/manifest"
[[ "$version" =~ ^[1-9][0-9]{0,15}$ && "$digest" =~ ^[0-9a-f]{64}$ && -z "$extra" ]]
current=""
if [[ -f "$root/current" ]]; then
    current="$(cat "$root/current")"
fi
if [[ "$current" =~ ^[1-9][0-9]{0,15}$ ]]; then
    if (( current > version )); then
        echo "The engine channel returned an older package."
        exit 1
    fi
    if (( current == version )) && [[ -x "$root/$current/engine/ytdl-engine" && ! -e "$root/$current/bin/gallery-dl" ]]; then
        if [[ "$mode" != install ]]; then
            /usr/bin/touch "$root/checked"
            echo "No newer tools package is available."
            exit 0
        fi
    fi
fi

stage="Downloading the engine archive"
echo "STEP 2"
download 900 "$work/kit.zip" --progress-bar --show-error "$url.zip" 2>&1 |
    /usr/bin/tr '\r' '\n' |
    while IFS= read -r line; do
        if [[ "$line" =~ ([0-9]+([.][0-9]+)?)% ]]; then
            printf 'PROGRESS %s\n' "${BASH_REMATCH[1]}"
        elif [[ -n "$line" ]]; then
            printf '%s\n' "$line"
        fi
    done
stage="Verifying the archive checksum"
echo "STEP 3"
actual="$(/usr/bin/shasum -a 256 "$work/kit.zip")"
[[ "${actual%% *}" == "$digest" ]]
stage="Extracting the engine archive"
echo "STEP 4"
kit="$work/kit"
/usr/bin/ditto -x -k "$work/kit.zip" "$kit"
[[ ! -e "$kit/bin/gallery-dl" ]] || { echo "The available engine kit predates this app build. Retry after a newer engine kit is published."; exit 1; }
stage="Checking the bundled tools"
echo "STEP 5"
"$kit/engine/ytdl-engine" check-parth
"$kit/bin/yt-dlp" --version >/dev/null
"$kit/bin/ffmpeg" -version >/dev/null
"$kit/bin/ffprobe" -version >/dev/null
"$kit/bin/deno" --version >/dev/null
stage="Activating the tool kit"
if [[ -e "$root/$version" ]]; then
    # A previous launch may still use this directory. Keep it until the new kit is placed.
    /bin/mv "$root/$version" "$work/previous"
fi
if ! /bin/mv "$kit" "$root/$version"; then
    if [[ -d "$work/previous" ]]; then /bin/mv "$work/previous" "$root/$version"; fi
    exit 1
fi
if ! printf '%s\n' "$version" > "$work/current" || ! /bin/mv -f "$work/current" "$root/current"; then
    /bin/mv "$root/$version" "$kit"
    if [[ -d "$work/previous" ]]; then /bin/mv "$work/previous" "$root/$version"; fi
    exit 1
fi
/usr/bin/touch "$root/checked"
if [[ "$mode" == install ]]; then
    echo "Tools installed."
else
    echo "Tools updated. The new versions will be used after restarting the app."
fi
