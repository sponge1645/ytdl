# Media Downloader

A native macOS app for downloading video and music. Paste a link with ⌘V or drop it onto the window. The queue shows video thumbnails and download progress.

## Downloads

- Download individual videos or start the entire queue. Playlist links expand into individual entries, and playlist positions are added to filenames.
- Save video as QuickTime-compatible MP4. The app uses compatible H.264/AAC streams when available and converts when needed. The selected resolution sets an upper limit.
- Save audio as MP3 or M4A. The music engine also supports FLAC and provider-specific Dolby formats.
- Add tracks, albums and playlists from music services including Spotify, Apple Music, Tidal, Qobuz and Deezer. Depending on the link, the app reads the track information from the linked service and downloads audio from the selected source.
- Download public Instagram Reels with yt-dlp and public photo posts and carousels with parth-dl. Photo posts and carousels require a direct connection.

## Install on macOS

Download the Universal ZIP from [Releases](https://github.com/sponge1645/ytdl/releases), extract it, and move the app to Applications. The app runs on Intel and Apple Silicon. On first launch it downloads a signed engine kit for the current architecture. The first setup requires an internet connection.

Use **Media Downloader → Check for Updates…** to check for a new app release. Automatic checks can be disabled in **Settings → General**. Engine updates are managed separately.

## Build locally

Build the full Universal app on macOS with Xcode and Rust installed through rustup. Set the public key for the engine update channel:

```bash
cd ~/ytdl
git pull --ff-only
YTDL_BUILD_SAFARI=1 YTDL_TOOLS_PUBLIC_KEY="$(cat "$HOME/ytdl-signing/public.pem")" bash build-music.sh
open "dist/universal/Media Downloader.app"
```

The full build requires macOS 11 or newer and uses Python 3 for music downloads. The macOS build workflow starts on manual dispatch. You can download the `YTDL-Universal` artifact from a successful [macOS workflow run](https://github.com/sponge1645/ytdl/actions/workflows/macos.yml). Building an engine kit locally with `bash build-macos.sh --engine-kit` also requires Python 3.11 or newer and internet access.

## Engine update channel

Signed engine kits are published under the `tools-v1` tag. The app checks the channel at launch, at most once a day after a successful check. It verifies the signed manifest and archive digest, then checks that the installed tools launch. Updates take effect after restarting the app. A failed update leaves the previous kit available. Kits are stored in `~/Library/Application Support/YTDL/tool-kits-v1/`.

Publishing jobs use the built-in GitHub Actions token with `contents: write`. The repository must be public for the app to fetch releases without authentication.

Generate a signing key pair once on a trusted machine:

```bash
umask 077
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out tools-private.pem
openssl pkey -in tools-private.pem -pubout -out tools-public.pem
```

Store the private key in the Actions secret `YTDL_TOOLS_SIGNING_KEY` and the public key in the Actions variable `YTDL_TOOLS_PUBLIC_KEY`. Build the app with the matching public key.

The weekly workflow checks stable yt-dlp releases on PyPI. For automatic publication, all usable files for a candidate release must be at least 48 hours old. Both architectures must pass download and MP4 checks before signing and publishing. If YouTube explicitly blocks a runner with its bot verification, the workflow records a warning and checks downloading and remuxing a local media fixture instead. Other YouTube errors fail the run. Other tools use pinned versions. For a manual release, set `publish=true` and supply a public Instagram photo or carousel post via `instagram_url` or `YTDL_INSTAGRAM_SMOKE_URL`. Scheduled runs also test Instagram if the variable is set. Override the YouTube test URL with `smoke_url` or `YTDL_YOUTUBE_SMOKE_URL`.

## License

YTDL source code is available under the [MIT License](LICENSE). See [Third-party notices](THIRD_PARTY_NOTICES.md) for the engine components.

## Safari extension

The full Universal build includes the Safari extension.
Open the resulting app once, then enable **Media Downloader** in
**Safari → Settings → Extensions** and grant access to YouTube. For a local
ad-hoc build, enable **Allow Unsigned Extensions** in the Safari Develop menu
to test it.

On a YouTube watch page, **Download** beside the Like and Dislike buttons
opens the app and adds the current video. The app's automatic download
preference determines whether downloading starts immediately. The extension
only needs access to YouTube watch pages and sends the current video ID to
the app.
