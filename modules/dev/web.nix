self:

{ config, pkgs, ... }:

let
  settingsFormat = pkgs.formats.json { };
in
{
  imports = with self.nixosModules; [
    home
    options
  ];

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

  # Browser CLI for agents: reads pages over HTTP and drives Chromium when needed.
  environment.systemPackages = with pkgs; [ agent-browser ];

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
