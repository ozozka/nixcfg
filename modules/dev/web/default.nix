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

  # Playwright's browser CLI from the nixpkgs driver, under the command name its skill and help
  # use (npm `@playwright/cli`). Chromium only: the driver's default set has every browser.
  # A project `.playwright/cli.config.json` replaces this config instead of merging with it.
  playwrightCli = pkgs.writeShellScriptBin "playwright-cli" ''
    export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers-chromium}
    export PLAYWRIGHT_MCP_CONFIG=${playwrightConfig}
    exec ${pkgs.nodejs}/bin/node ${pkgs.playwright-driver}/cli.js cli "$@"
  '';
  playwrightConfig = settingsFormat.generate "playwright-cli.json" {
    browser = {
      # Unset, Playwright uses the Chrome channel, which is not installed.
      browserName = "chromium";
      # A persistent profile per session, so logins survive closing the browser.
      isolated = false;
      launchOptions = {
        # A visible window shows what agents do.
        headless = false;
        # Own window class, so Hyprland places it on its workspace.
        args = [ "--class=playwright-cli" ];
      };
      contextOptions.colorScheme = if config.ozozka.col.isDark then "dark" else "light";
    };
    # Headed browsers otherwise stay open until closed.
    timeouts.idle = 30 * 60 * 1000;
  };
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

  # Browser CLI for agents: reads pages over HTTP and drives Chromium when needed.
  environment.systemPackages = [
    pkgs.agent-browser
    playwrightCli
    webSearch
  ];

  # Snapshots and screenshots of playwright-cli, kept in the project it ran in.
  programs.git.config.core.excludesFile = pkgs.writeText "git-ignore" ".playwright-cli/\n";

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
