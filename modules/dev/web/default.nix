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

  # Page reader for agents (the web skill): trafilatura extracts the main text, Playwright
  # renders pages built by JavaScript in playwright-cli's Chromium, PyMuPDF reads PDFs.
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
  imports = [ self.nixosModules.options ];

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

  # Web tools for agents: search, page reading over HTTP, and the browser.
  environment.systemPackages = [
    playwrightCli
    webFetch
    webSearch
  ];

  # Snapshots and screenshots of playwright-cli, kept in the project it ran in.
  programs.git.config.core.excludesFile = pkgs.writeText "git-ignore" ".playwright-cli/\n";

}
