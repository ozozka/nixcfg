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

  environment.systemPackages = with pkgs; [ codex ];

  ozozka.home.profiles.codex.files.".codex/hooks.json" = settingsFormat.generate "codex-hooks.json" {
    hooks = {
      SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "${pkgs.python3}/bin/python3 ${./docs.py}";
              timeout = 10;
              additionalContextLimit = 0;
            }
          ];
        }
      ];
      Stop = [ { hooks = [ notification ]; } ];
      PermissionRequest = [ { hooks = [ notification ]; } ];
      PreToolUse = [
        {
          matcher = "^request_user_input$";
          hooks = [ notification ];
        }
      ];
    };
  };
}
