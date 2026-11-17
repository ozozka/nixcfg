"""Read a web page as Markdown, shaped like the agents' built-in fetch tools.

Asks for Markdown first, which some sites serve to agents; otherwise extracts the main
text of the HTML with trafilatura, keeping headings, links, and tables. Pages whose HTML
has little text are rendered in headless Chromium and extracted again, since many are
built by JavaScript. PDFs are converted to Markdown. Long results are read in parts with
--start. The Chromium binary is supplied by Nix through WEB_FETCH_CHROMIUM.
"""

import argparse
import contextlib
import io
import os
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
HTML_TYPES = ("text/html", "application/xhtml+xml")
# Markdown link targets, resolved against the page URL.
LINK = re.compile(r"\]\(([^)\s]+)\)")
# HTML with less text than this is rendered in the browser; output shorter than this after
# rendering gets a hint that the page may need the interactive browser.
SHORT_CHARS = 300
# Seconds to wait for a page to load, and then for its requests to settle.
LOAD_TIMEOUT = 30
SETTLE_TIMEOUT = 5


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def offset(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must be at least 0")
    return number


def parse_args():
    parser = argparse.ArgumentParser(
        prog="web-fetch", description="Read a web page as Markdown."
    )
    parser.add_argument("url")
    parser.add_argument(
        "--max-chars",
        type=positive,
        default=36000,
        metavar="N",
        help="print at most N characters (default: 36000)",
    )
    parser.add_argument(
        "--start",
        type=offset,
        default=0,
        metavar="N",
        help="start at character N, to continue a cut result (default: 0)",
    )
    parser.add_argument(
        "--render",
        action="store_true",
        help="render the page in headless Chromium even when its HTML has text",
    )
    return parser.parse_args()


def fetch(url):
    request = urllib.request.Request(url, headers=HEADERS)
    with urllib.request.urlopen(request, timeout=LOAD_TIMEOUT) as response:
        content_type = response.headers.get_content_type()
        charset = response.headers.get_content_charset() or "utf-8"
        return response.geturl(), content_type, charset, response.read()


def render(url):
    """Return the final URL and the HTML of a page after its scripts ran."""
    from playwright.sync_api import TimeoutError as PlaywrightTimeout
    from playwright.sync_api import sync_playwright

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(executable_path=os.environ["WEB_FETCH_CHROMIUM"])
        try:
            page = browser.new_page()
            page.goto(url, wait_until="load", timeout=LOAD_TIMEOUT * 1000)
            # Applications keep fetching after load; pages that never go quiet are read as they are.
            with contextlib.suppress(PlaywrightTimeout):
                page.wait_for_load_state("networkidle", timeout=SETTLE_TIMEOUT * 1000)
            return page.url, page.content()
        finally:
            browser.close()


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


def pdf_text(body):
    # pymupdf4llm prints a notice on import, which would mix into the output.
    with contextlib.redirect_stdout(io.StringIO()):
        import pymupdf
        import pymupdf4llm
    with pymupdf.open(stream=body, filetype="pdf") as document:
        return pymupdf4llm.to_markdown(document, show_progress=False)


def read(url, render_page):
    """Return the final URL and the Markdown of a page, or exit with an error."""
    if render_page:
        url, html = render(url)
        return url, extract(html, url).strip()
    url, content_type, charset, body = fetch(url)
    if content_type in TEXT_TYPES:
        return url, body.decode(charset, errors="replace").strip()
    if content_type == "application/pdf":
        return url, pdf_text(body).strip()
    if content_type not in HTML_TYPES:
        raise ValueError(f"unsupported content type {content_type}")
    text = extract(body, url).strip()
    if len(text) < SHORT_CHARS:
        # Rendering is a best effort here: where the browser cannot run or connect (such as an
        # agent sandbox), the HTML text stands, and its short-page hint points to the browser.
        try:
            rendered_url, html = render(url)
        except Exception as error:  # noqa: BLE001 - Playwright raises its own errors.
            print(f"web-fetch: cannot render {url}: {error}", file=sys.stderr)
            return url, text
        rendered = extract(html, rendered_url).strip()
        if len(rendered) > len(text):
            return rendered_url, rendered
    return url, text


def main():
    args = parse_args()
    try:
        url, text = read(args.url, args.render)
    except urllib.error.HTTPError as error:
        print(f"web-fetch: HTTP {error.code} {error.reason} at {args.url}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - Playwright and PyMuPDF raise their own errors.
        print(f"web-fetch: cannot read {args.url}: {error}", file=sys.stderr)
        return 1

    if not text:
        print(
            f"web-fetch: no readable text at {url}; read it in the browser (`browser` skill)",
            file=sys.stderr,
        )
        return 1
    if args.start >= len(text):
        print(
            f"web-fetch: --start {args.start} is past the end ({len(text)} characters)",
            file=sys.stderr,
        )
        return 1

    end = min(args.start + args.max_chars, len(text))
    print(url, end="\n\n")
    print(text[args.start : end])
    if args.start or end < len(text):
        notice = f"characters {args.start}-{end} of {len(text)}"
        if end < len(text):
            notice += f"; continue with --start {end}"
        print(f"\n[web-fetch: {notice}]")
    if len(text) < SHORT_CHARS:
        print("\n[web-fetch: short page; if content is missing, read it in the browser]")
    return 0


if __name__ == "__main__":
    sys.exit(main())
