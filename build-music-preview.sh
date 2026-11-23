#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
: "${YTDL_TOOLS_PUBLIC_KEY:?Set YTDL_TOOLS_PUBLIC_KEY to the public engine update key}"
if [[ "$(uname -s)" != Darwin ]]; then
    echo "This preview must be built on macOS." >&2
    exit 1
fi

if [[ -z "${YTDL_MUSIC_ENGINE_LIBRARY:-}" ]]; then
    command -v rustup >/dev/null || {
        echo "Install Rust with rustup and make sure rustup is on PATH." >&2
        exit 1
    }
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    git -C "$work" init -q
    git -C "$work" fetch -q --depth 1 https://github.com/mornyeapp/Mornye.git c4a1c7b812eb135d6e1a295b6b25e11abbd72a7e
    git -C "$work" checkout -q --detach FETCH_HEAD
    (cd "$work" && bash scripts/build_rust_backend.sh desktop)
    export YTDL_MUSIC_ENGINE_LIBRARY="$work/rust_backend/target/desktop/macos/libmornye_desktop.dylib"
fi

bash build-macos.sh --universal
