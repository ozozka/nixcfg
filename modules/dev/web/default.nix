self:

{ config, pkgs, ... }:

let
  settingsFormat = pkgs.formats.json { };
  searxPort = 8888;

  # Search command for agents (the web skill); Python only, no extra packages.
  webSearch = pkgs.writeShellScriptBin "web-search" ''
    WEB_SEARCH_ENDPOINT=http://127.0.0.1:${toString searxPort} \
      exec ${pkgs.python3}/bin/python3 -I ${./web-search.py} "$@"
  '';
in
{
  imports = with self.nixosModules; [
    home
    options
  ];

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
      # JSON for web-search; it carries publication dates, unlike CSV.
      search.formats = [
        "html"
        "json"
      ];
    };
  };

  # Browser CLI for agents: reads pages over HTTP and drives Chromium when needed.
  environment.systemPackages = [
    pkgs.agent-browser
    webSearch
  ];

  ozozka.home.profiles.web.files.".agent-browser"."config.json" =
    settingsFormat.generate "agent-browser.json"
      {
        # The package does not wire a browser.
        executablePath = "${pkgs.chromium}/bin/chromium";
        # A visible window shows what agents do; `--headed false` for a single run.
        headed = true;
        # Own window class, so Hyprland places it on its workspace.
        args = "--class=agent-browser";
        # Headed browsers otherwise stay open until closed.
        idleTimeout = "30m";
        colorScheme = if config.ozozka.col.isDark then "dark" else "light";
        # Marks page text as untrusted against prompt injection.
        contentBoundaries = true;
        maxOutput = 40000;
      };
}
