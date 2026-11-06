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

  environment.etc."claude-code/managed-settings.json".source =
    settingsFormat.generate "claude-managed-settings.json"
      {
        theme = if config.ozozka.col.isDark then "dark-ansi" else "light-ansi";
        tui = "default";
        disableAgentView = true;
        attribution = {
          commit = "";
          pr = "";
        };
        statusLine = {
          type = "command";
          command = "${python} ${./statusline.py} ${pkgs.git}/bin/git";
          padding = 0;
          refreshInterval = 30;
        };
        hooks = {
          SessionStart = [
            {
              matcher = "^(startup|clear|compact)$"; # Resumed sessions already carry the documentation in their transcript.
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
