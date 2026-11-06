#!/usr/bin/env python3
"""Mirror the Discworld MUD's official web documentation into testing_facility/.

Polite BFS over discworld.starturtle.net, scoped to the official /lpc/playing and
/lpc/about trees plus the documentation.c browser (concepts, helpdir, newbie,
rules, room, object). Player homepages (/lpc/~), forums, and assets are excluded.
Rate-limited (default 0.4 s between requests), resumable (existing files are
kept), and writes an index.tsv (url -> file, status) plus index.json.

Usage: python3 tools/mirror_discworld_docs.py [--out DIR] [--delay SECONDS] [--fresh]
"""

import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request
from html.parser import HTMLParser

HOST = "discworld.starturtle.net"
BASE = f"https://{HOST}"

SEEDS = [
    f"{BASE}/lpc/playing/",
    f"{BASE}/lpc/about/",
    f"{BASE}/lpc/playing/documentation.c?path=/concepts",
    f"{BASE}/lpc/playing/documentation.c?path=/newbie/essentials",
    f"{BASE}/lpc/playing/documentation.c?path=/helpdir",
    f"{BASE}/lpc/playing/documentation.c?path=/concepts/rules",
    f"{BASE}/lpc/playing/documentation.c?path=/room/",
    f"{BASE}/lpc/playing/documentation.c?path=/object/",
    f"{BASE}/lpc/playing/clients.html",
    f"{BASE}/lpc/playing/getting_started.html",
    f"{BASE}/lpc/playing/guilds.html",
]

ALLOWED_PREFIXES = (f"https://{HOST}/lpc/playing", f"https://{HOST}/lpc/about")
EXCLUDE_MARKERS = ("/lpc/~", "/forum", "/cgi-bin", "/external/")
SKIP_EXT = (".png", ".jpg", ".gif", ".css", ".js", ".ico", ".mp3", ".pdf")


class LinkExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []
        self.title = ""
        self._in_title = False

    def handle_starttag(self, tag, attrs):
        if tag == "a":
            for name, value in attrs:
                if name == "href" and value:
                    self.links.append(value)
        elif tag == "title":
            self._in_title = True

    def handle_data(self, data):
        if self._in_title:
            self.title += data

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False


def normalize(href, base_url):
    absolute = urllib.parse.urljoin(base_url, href.split("#")[0])
    parsed = urllib.parse.urlparse(absolute)
    if parsed.scheme not in ("http", "https") or parsed.netloc != HOST:
        return None
    if any(parsed.path.startswith(marker) for marker in ("/lpc/~",)) or any(
        marker in absolute for marker in EXCLUDE_MARKERS
    ):
        return None
    if parsed.path.lower().endswith(SKIP_EXT):
        return None
    if not (
        parsed.path.startswith("/lpc/playing") or parsed.path.startswith("/lpc/about")
    ):
        return None
    return urllib.parse.urlunparse(parsed)


def slugify(url):
    parsed = urllib.parse.urlparse(url)
    slug = parsed.path.strip("/").replace("/", "_") or "index"
    if parsed.query:
        slug += "__" + urllib.parse.quote_plus(parsed.query, safe="")
    return slug[:180] + ".html"


def fetch(url, timeout=20):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "hex-testing-facility-mirror/1.0 (Discworld docs offline reference)"
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--out",
        default=os.path.join(
            os.path.dirname(__file__) or ".", "..", "testing_facility", "discworld-docs"
        ),
    )
    ap.add_argument("--delay", type=float, default=0.4)
    ap.add_argument(
        "--fresh", action="store_true", help="re-download even if the file exists"
    )
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    pages_dir = os.path.join(out, "pages")
    os.makedirs(pages_dir, exist_ok=True)

    index_path = os.path.join(out, "index.json")
    index = {}
    if os.path.exists(index_path) and not args.fresh:
        with open(index_path) as fh:
            index = json.load(fh)

    queue = list(dict.fromkeys(SEEDS))
    seen = {
        url
        for url, entry in index.items()
        if not str(entry.get("status", "")).startswith("error")
    }
    queue += [
        url
        for url, entry in index.items()
        if str(entry.get("status", "")).startswith("error")
    ]
    done = 0
    session_log = []

    while queue:
        url = queue.pop(0)
        if url in seen:
            continue
        seen.add(url)
        slug = slugify(url)
        path = os.path.join(pages_dir, slug)

        body, title, status = None, "", "error"
        if os.path.exists(path) and not args.fresh and url in index:
            status = "cached"
        else:
            try:
                body = fetch(url)
                time.sleep(args.delay)
                parser = LinkExtractor()
                try:
                    parser.feed(body.decode("utf-8", errors="replace"))
                    title = parser.title.strip()
                except Exception:  # noqa: BLE001 -- best-effort: malformed pages still mirror
                    title = ""
                with open(path, "wb") as fh:
                    fh.write(body)
                status = "fetched"
                for href in parser.links:
                    normalized = normalize(href, url)
                    if normalized and normalized not in seen:
                        queue.append(normalized)
            except Exception as exc:  # noqa: BLE001 -- best-effort crawl: log and move on
                status = f"error: {exc}"
            done += 1
            if done % 25 == 0:
                print(f"[{done}] queue {len(queue)} last={status} {url}", flush=True)

        index[url] = {
            "file": os.path.relpath(path, out),
            "status": status,
            "title": title,
        }
        session_log.append((url, status))

        if status == "fetched":
            with open(index_path, "w") as fh:
                json.dump(index, fh, indent=1, sort_keys=True)

    with open(index_path, "w") as fh:
        json.dump(index, fh, indent=1, sort_keys=True)
    errors = [u for u, s in session_log if s.startswith("error")]
    print(
        f"done: {len(index)} urls known, {done} fetched this run, {len(errors)} errors"
    )
    for url in errors[:20]:
        print("  ERROR:", url)
    return 0 if not errors else 1


if __name__ == "__main__":
    sys.exit(main())
