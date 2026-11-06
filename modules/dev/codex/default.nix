_:

{ pkgs, ... }:

let
  settingsFormat = pkgs.formats.toml { };
  python = "${pkgs.python3}/bin/python3";
  notification = {
    type = "command";
    command = "${python} ${./notify.py} ${pkgs.systemd}/bin/busctl";
    timeout = 6;
  };
in
{
  environment.systemPackages = with pkgs; [ codex ];

  # System layer: defaults below ~/.codex/config.toml, which stays writable for
  # Codex's own state (trust, notices). Keys set there override these.
  environment.etc."codex/config.toml".source = settingsFormat.generate "codex-config.toml" {
    tui = {
      # Inline renderer: output lands in terminal scrollback (ansi-term).
      alternate_screen = "never";
      theme = "ansi";
      status_line = [
        "model-with-reasoning"
        "current-dir"
        "thread-name"
        "reasoning"
        "run-state"
        "context-used"
        "five-hour-limit"
        "weekly-limit"
      ];
      status_line_use_colors = true;
    };
    hooks = {
      SessionStart = [
        {
          hooks = [
            {
              type = "command";
              command = "${python} ${./docs.py}";
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
