self:

{ lib, ... }:

let
  inherit (lib) mkOption types;
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

    modes = mkOption {
      type = types.attrsOf types.lines;
      default =
        let
          roadmap = "\n" + builtins.readFile ./modes/roadmap.md;
        in
        {
          plan = builtins.readFile ./modes/plan.md;
          spec = builtins.readFile ./modes/spec.md + roadmap;
          exec = builtins.readFile ./modes/exec.md + roadmap;
        };
      description = "Explicitly selected workflow instructions shared by modes and output styles.";
    };

    tools = mkOption {
      type = types.attrsOf types.path;
      default = entries ./tools;
      description = "Tool-help Markdown by file name, loaded only by its consumer.";
    };

    subagents = mkOption {
      type = types.attrsOf types.path;
      default = entries ./subagents;
      description = "Delegated role definitions; consumers choose which roles to expose.";
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
}
