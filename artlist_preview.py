"""Resolve previews for individual Artlist assets."""
import json
import re
from urllib.parse import urlsplit


ARTLIST_ROOT = "https://artlist.io/"
ROUTES = {"/royalty-free-music/song/": "songs", "/sfx/track/": "sfxs",
          "/stock-footage/clip/": "clip"}


def artlist_asset(url):
    parts = urlsplit(url)
    if parts.scheme != "https" or parts.hostname not in {"artlist.io", "www.artlist.io"}:
        return None
    for path, kind in ROUTES.items():
        match = re.fullmatch(re.escape(path) + r"[^/]+/([0-9]{1,10})/?", parts.path)
        if match:
            return kind, match[1]
    return None


def preview_url(item, fields):
    for field in fields:
        url = item.get(field)
        if not isinstance(url, str):
            continue
        parsed = urlsplit(url)
        if (parsed.scheme == "https" and parsed.hostname and parsed.hostname.endswith(".artlist.io")
                and not parsed.username and not parsed.password and parsed.port in (None, 443)):
            return url
    return None


def clip_objects(page):
    decoder = json.JSONDecoder()
    chunks = [page]
    for match in re.finditer(r"self\.__next_f\.push\(", page):
        try:
            value, _ = decoder.raw_decode(page, match.end())
        except ValueError:
            continue
        if isinstance(value, list):
            chunks.extend(part for part in value if isinstance(part, str))
    for chunk in chunks:
        for match in re.finditer(r'{\s*"(?:(?:id|clipId|clipName|clipPath|title|name|hlsUrl|previewVideoUrl)"\s*:)', chunk):
            try:
                value, _ = decoder.raw_decode(chunk, match.start())
            except ValueError:
                continue
            yield value


def resolve_artlist(url, proxy=""):
    from yt_dlp import YoutubeDL
    from yt_dlp.networking import Request
    from yt_dlp.networking.exceptions import RequestError

    kind, asset_id = artlist_asset(url)
    headers = {"Referer": ARTLIST_ROOT}
    if kind == "clip":
        request = Request(url, headers=headers)
    else:
        id_type = "String" if kind == "songs" else "Int"
        ids = [asset_id] if kind == "songs" else [int(asset_id)]
        query = f"query Preview($ids: [{id_type}!]!) {{ {kind}(ids: $ids) {{ songId songName sitePlayableFilePath }} }}"
        request = Request("https://search-api.artlist.io/v1/graphql",
                          data=json.dumps({"query": query, "variables": {"ids": ids}}).encode(),
                          headers={**headers, "Content-Type": "application/json"})

    try:
        with YoutubeDL({"quiet": True, "socket_timeout": 15, "proxy": proxy or None}) as downloader:
            with downloader.urlopen(request) as response:
                body = response.read(8 * 1024 * 1024 + 1)
    except RequestError as error:
        status = getattr(error, "status", None)
        detail = f" (HTTP {status})" if isinstance(status, int) else ""
        raise RuntimeError(f"Could not read the Artlist preview{detail}.") from None
    if len(body) > 8 * 1024 * 1024:
        raise RuntimeError("The Artlist preview response is too large.")
    if kind == "clip":
        items = clip_objects(body.decode("utf-8", errors="replace"))
        id_fields = ("clipId", "id")
        media_fields = ("clipPath", "hlsUrl", "previewVideoUrl")
        title_fields = ("clipName", "title", "name")
    else:
        items = (json.loads(body).get("data") or {}).get(kind) or []
        id_fields = ("songId",)
        media_fields = ("sitePlayableFilePath",)
        title_fields = ("songName",)
    for item in items:
        if not isinstance(item, dict) or not any(str(item.get(field)) == asset_id for field in id_fields):
            continue
        media = preview_url(item, media_fields)
        if media and (kind != "clip" or urlsplit(media).path.lower().endswith((".m3u8", ".mp4"))):
            title = next((item[field] for field in title_fields if isinstance(item.get(field), str)
                          and item[field].strip()), f"Artlist {asset_id}")
            return media, title
    raise RuntimeError("Artlist did not expose a preview for this exact asset.")
