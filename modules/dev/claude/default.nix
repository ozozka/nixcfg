self:

{ config, pkgs, ... }:

let
  agents = config.ozozka.mod.dev.agents;
  settingsFormat = pkgs.formats.json { };
  python = "${pkgs.python3}/bin/python3";
  notification = {
    type = "command";
    command = "${python} ${./notify.py} ${pkgs.systemd}/bin/busctl";
    timeout = 6;
  };
  managedSettings = settingsFormat.generate "claude-managed-settings.json" {
    theme = if config.ozozka.col.isDark then "dark-ansi" else "light-ansi";
    tui = "default";
    disableAgentView = true;
    # Commands of the shared web skill.
    permissions.allow = [
      "Bash(web-search:*)"
      "Bash(agent-browser:*)"
    ];
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
in
{
  imports = with self.nixosModules; [
    home
    options
  ];

  nixpkgs.config.allowUnfreePackages = [ "claude-code" ];

  environment = {
    systemPackages = [
      pkgs.claude-code
      # Claude Code with the personal workflow appended to its system prompt.
      (pkgs.writeShellScriptBin "wclaude" ''exec ${pkgs.claude-code}/bin/claude --append-system-prompt "$(< ${agents.workflow})" "$@"'')
    ];

    # Shared agent instructions and skills use Claude Code's managed (system-wide) locations.
    etc = {
      "claude-code/managed-settings.json".source = managedSettings;
      "claude-code/CLAUDE.md".source = agents.instructions;
      "claude-code/.claude/skills".source = pkgs.linkFarm "claude-skills" agents.skills;
    };
  };

  ozozka.home.profiles.claude.files.".claude".commands = agents.prompts;
}
