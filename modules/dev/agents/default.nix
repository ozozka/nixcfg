self:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkOption types;
  cfg = config.ozozka;
  statsPython = pkgs.python3.withPackages (p: [ p.nicegui ]);
  # The browser agent-stats opens its app in.
  statsBrowser = "${self.packages.${pkgs.stdenv.hostPlatform.system}.zen-browser}/bin/zen";
  statsTheme = (pkgs.formats.json { }).generate "agent-stats-theme.json" {
    dark = cfg.col.isDark;
    colors = lib.mapAttrs (_: color: color.hex) (lib.removeAttrs cfg.col [ "isDark" ]);
    fonts = {
      sans = cfg.font.sans.name;
      mono = cfg.font.mono.name;
    };
    inherit (cfg) fontSize dim;
  };
  # Each entry of a directory as its own path, so consumers can link entries
  # individually beside files the agents create themselves.
  entries = dir: lib.mapAttrs (name: _: dir + "/${name}") (builtins.readDir dir);
in
{
  imports = [ self.nixosModules.options ];

  # Agent-agnostic assets. Each agent module links them into its own locations.
  options.ozozka.mod.dev.agents = {
    instructions = mkOption {
      type = types.path;
      default = ./AGENTS.md;
      description = "Global instructions shared by every agent.";
    };

    workflow = mkOption {
      type = types.path;
      default = ./workflow.md;
      description = "Personal workflow instructions, loaded only by the workflow wrappers.";
    };

    prompts = mkOption {
      type = types.attrsOf types.path;
      default = entries ./prompts;
      description = "Prompt templates by file name, exposed as slash commands.";
    };

    skills = mkOption {
      type = types.attrsOf types.path;
      default = entries ./skills;
      description = "Agent Skills directories by skill name.";
    };
  };

  # A local app of what the agents' model requests contained, styled with the system theme.
  config.environment.systemPackages = [
    (pkgs.writeShellScriptBin "agent-stats" "exec ${statsPython}/bin/python3 ${./stats.py} ${statsTheme} ${statsBrowser}")
  ];
}
