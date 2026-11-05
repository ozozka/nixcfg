{ config, pkgs, ... }:

let
  settingsFormat = pkgs.formats.json { };
  python = "${pkgs.python3}/bin/python3";
  notification = {
    type = "command";
    command = "${python} ${./notify.py} ${pkgs.systemd}/bin/busctl";
    timeout = 6;
  };
in
{
  imports = [ ../../options.nix ];

  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];

  environment.systemPackages = with pkgs; [ claude-code ];

  # Managed settings take precedence over user settings, and hooks from both run.
  # ~/.claude/settings.json stays writable for Claude's own state.
  environment.etc."claude-code/managed-settings.json".source =
    settingsFormat.generate "claude-managed-settings.json"
      {
        # ANSI themes follow the terminal palette, like the Pi theme.
        theme = if config.ozozka.col.isDark then "dark-ansi" else "light-ansi";
        statusLine = {
          type = "command";
          command = "${python} ${./statusline.py} ${pkgs.git}/bin/git";
          padding = 0;
          # Keep reset countdowns moving while the session is idle.
          refreshInterval = 30;
        };
        hooks = {
          SessionStart = [
            {
              # Resumed sessions already carry the documentation in their transcript.
              matcher = "^(startup|clear|compact)$";
              hooks = [
                {
                  type = "command";
                  command = "${python} ${./docs.py}";
                  timeout = 10;
                }
              ];
            }
          ];
          Stop = [ { hooks = [ notification ]; } ];
          StopFailure = [ { hooks = [ notification ]; } ];
          Notification = [
            {
              matcher = "^(permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input)$";
              hooks = [ notification ];
            }
          ];
        };
      };
}
