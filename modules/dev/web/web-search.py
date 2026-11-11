"""Web search through the local SearXNG, shaped like the agents' built-in search tools.

One query per call with allowed and blocked domains, as in Claude's and OpenAI's web
search. Prints numbered results: title and date, URL, snippet. The SearXNG address is
supplied by Nix through WEB_SEARCH_ENDPOINT.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be at least 1")
    return number


def parse_args():
    parser = argparse.ArgumentParser(
        prog="web-search", description="Search the web through the local SearXNG."
    )
    parser.add_argument("query")
    parser.add_argument(
        "--allowed-domain",
        action="append",
        default=[],
        metavar="DOMAIN",
        help="only return results from this domain or its subdomains (repeatable)",
    )
    parser.add_argument(
        "--blocked-domain",
        action="append",
        default=[],
        metavar="DOMAIN",
        help="never return results from this domain or its subdomains (repeatable)",
    )
    parser.add_argument(
        "--recency",
        choices=["day", "week", "month", "year"],
        help="only return results from this period",
    )
    parser.add_argument(
        "--limit",
        type=positive,
        default=12,
        metavar="N",
        help="number of results (default: 12)",
    )
    return parser.parse_args()


def normalize(domains):
    return [domain.lower().strip(".").removeprefix("www.") for domain in domains]


def matches(host, domains):
    return any(host == domain or host.endswith(f".{domain}") for domain in domains)


def search(endpoint, query, recency):
    params = {"q": query, "format": "json"}
    if recency:
        params["time_range"] = recency
    url = f"{endpoint}/search?{urllib.parse.urlencode(params)}"
    with urllib.request.urlopen(url, timeout=20) as response:
        return json.load(response)


def format_result(index, result):
    date = (result.get("publishedDate") or "")[:10]
    title = " ".join((result.get("title") or "").split())
    lines = [f"{index}. {title}" + (f" ({date})" if date else ""), result["url"]]
    if content := " ".join((result.get("content") or "").split()):
        lines.append(content)
    return "\n".join(lines)


def main():
    args = parse_args()
    endpoint = os.environ["WEB_SEARCH_ENDPOINT"]
    allowed = normalize(args.allowed_domain)
    blocked = normalize(args.blocked_domain)

    # Engines narrow results with site: terms; the filter below still enforces the
    # domains because not every engine honors them.
    query = args.query
    if allowed:
        query += " " + " OR ".join(f"site:{domain}" for domain in allowed)

    try:
        data = search(endpoint, query, args.recency)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        print(f"web-search: SearXNG unreachable at {endpoint}: {error}", file=sys.stderr)
        return 1

    results = []
    for result in data.get("results", []):
        host = urllib.parse.urlsplit(result.get("url", "")).hostname or ""
        if (allowed and not matches(host, allowed)) or matches(host, blocked):
            continue
        results.append(result)
        if len(results) == args.limit:
            break

    if not results:
        failed = ", ".join(
            f"{name} ({reason})" for name, reason in data.get("unresponsive_engines", [])
        )
        print(
            "web-search: no results" + (f"; failed engines: {failed}" if failed else ""),
            file=sys.stderr,
        )
        return 1

    print("\n\n".join(format_result(index, result) for index, result in enumerate(results, 1)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
