self:

{ pkgs, ... }:

let
  searxPort = 8888;

  # Search command for agents (the web skill); Python only, no extra packages. Agent sandboxes
  # exempt local addresses from their proxy but have no route to the host's SearXNG, so the
  # request goes through the proxy, whose policy can allow it.
  webSearch = pkgs.writeShellScriptBin "web-search" ''
    unset no_proxy NO_PROXY
    WEB_SEARCH_ENDPOINT=http://127.0.0.1:${toString searxPort} \
      exec ${pkgs.python3}/bin/python3 -I ${./web-search.py} "$@"
  '';

  # Page reader for agents (the web skill): trafilatura extracts the main text, Playwright
  # renders pages built by JavaScript in Playwright's Chromium, PyMuPDF reads PDFs.
  webFetch = pkgs.writeShellScriptBin "web-fetch" ''
    WEB_FETCH_CHROMIUM=${pkgs.playwright-driver.browsers-chromium}/chromium-${pkgs.playwright-driver.browsersJSON.chromium.revision}/chrome-linux64/chrome \
      exec ${
        pkgs.python3.withPackages (p: [
          p.trafilatura
          p.playwright
          p.pymupdf4llm
        ])
      }/bin/python3 -I ${./web-fetch.py} "$@"
  '';
in
{
  # Local metasearch for agents: queries several engines, so one engine throttling or
  # asking for a CAPTCHA does not stop search.
  services.searx = {
    enable = true;
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = searxPort;
        # Required by SearXNG; it signs only local cookies and image proxy URLs.
        secret_key = "ozozka-local-searxng";
      };
      search = {
        # JSON for web-search; it carries publication dates, unlike CSV.
        formats = [
          "html"
          "json"
        ];
        # Consistent English results instead of guessing from the query and locale.
        default_lang = "en";
      };
    };
  };

  # Web tools for agents: search and page reading.
  environment.systemPackages = [
    webFetch
    webSearch
  ];
}
