self:

{ config, pkgs, ... }:

let
  settingsFormat = pkgs.formats.json { };

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

  # The browser for agents (the browser skill).
  environment.systemPackages = [ playwrightCli ];

  # Snapshots and screenshots of playwright-cli, kept in the project it ran in.
  programs.git.config.core.excludesFile = pkgs.writeText "git-ignore" ".playwright-cli/\n";
}
