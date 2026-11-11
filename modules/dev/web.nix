_:

_:

{
  # Local metasearch for agents: queries several engines, so one engine throttling or
  # asking for a CAPTCHA does not stop search. The web skill depends on the address.
  services.searx = {
    enable = true;
    settings = {
      server = {
        bind_address = "127.0.0.1";
        port = 8888;
        # Required by SearXNG; it signs only local cookies and image proxy URLs.
        secret_key = "ozozka-local-searxng";
      };
      # CSV keeps agent context small: one line per result.
      search.formats = [
        "html"
        "csv"
        "json"
      ];
    };
  };
}
