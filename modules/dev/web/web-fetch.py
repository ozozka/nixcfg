"""Read a web page as Markdown over HTTP, shaped like the agents' built-in fetch tools.

Asks for Markdown first, which some sites serve to agents; otherwise extracts the main
text of the HTML with trafilatura, keeping headings, links, and tables. Pages that render
in the browser yield no text, so the exit status tells the agent to use the browser.
"""

import argparse
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import trafilatura

HEADERS = {
    "Accept": "text/markdown, text/html;q=0.9, text/plain;q=0.8, */*;q=0.1",
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) web-fetch",
}
TEXT_TYPES = ("text/markdown", "text/plain", "application/json", "text/xml", "application/xml")
# Markdown link targets, resolved against the page URL.
LINK = re.compile(r"\]\(([^)\s]+)\)")
# Below this, an extraction is a cookie banner or an empty application shell.
MIN_CHARS = 200


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def parse_args():
    parser = argparse.ArgumentParser(
        prog="web-fetch", description="Read a web page as Markdown over HTTP."
    )
    parser.add_argument("url")
    parser.add_argument(
        "--max-chars",
        type=positive,
        default=40000,
        metavar="N",
        help="cut the output after N characters (default: 40000)",
    )
    return parser.parse_args()


def fetch(url):
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=30) as response:
        content_type = response.headers.get_content_type()
        charset = response.headers.get_content_charset() or "utf-8"
        return response.geturl(), content_type, charset, response.read()


def extract(body, url):
    # Without `url`, trafilatura keeps links as written; with it, it resolves them against the
    # site root instead of the page.
    text = trafilatura.extract(
        body,
        output_format="markdown",
        include_links=True,
        include_tables=True,
        include_images=False,
        include_comments=False,
    )
    metadata = trafilatura.extract_metadata(body)
    title = metadata.title if metadata else None
    text = LINK.sub(lambda match: f"]({urllib.parse.urljoin(url, match[1])})", text or "")
    # Pages without their own heading get the document title.
    return (f"# {title}\n\n" if title and text and not text.startswith("#") else "") + text


def main():
    args = parse_args()
    try:
        url, content_type, charset, body = fetch(args.url)
    except urllib.error.HTTPError as error:
        print(f"web-fetch: HTTP {error.code} {error.reason} at {args.url}", file=sys.stderr)
        return 1
    except (urllib.error.URLError, TimeoutError, ValueError) as error:
        print(f"web-fetch: cannot fetch {args.url}: {error}", file=sys.stderr)
        return 1

    if content_type in TEXT_TYPES:
        text = body.decode(charset, errors="replace")
    elif content_type in ("text/html", "application/xhtml+xml"):
        text = extract(body, url)
    else:
        print(f"web-fetch: unsupported content type {content_type} at {url}", file=sys.stderr)
        return 1

    text = text.strip()
    if len(text) < MIN_CHARS and content_type not in TEXT_TYPES:
        print(
            f"web-fetch: no readable text at {url}; it may render in the browser: use playwright-cli",
            file=sys.stderr,
        )
        return 1

    print(url, end="\n\n")
    if len(text) > args.max_chars:
        print(text[: args.max_chars])
        print(
            f"\n[web-fetch: cut at {args.max_chars} of {len(text)} characters; see --max-chars]"
        )
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
