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
