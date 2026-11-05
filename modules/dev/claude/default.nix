{ pkgs, ... }:

let
  settingsFormat = pkgs.formats.json { };
  notification = {
    type = "command";
    command = "${pkgs.python3}/bin/python3 ${./notify.py} ${pkgs.systemd}/bin/busctl";
    timeout = 6;
  };
in
{
  imports = [ ../../home.nix ];

  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];

  environment.systemPackages = with pkgs; [ claude-code ];

  ozozka.home.profiles.claude.files.".claude/settings.json" =
    settingsFormat.generate "claude-settings.json"
      {
        hooks = {
          SessionStart = [
            {
              hooks = [
                {
                  type = "command";
                  command = "${pkgs.python3}/bin/python3 ${./docs.py}";
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
