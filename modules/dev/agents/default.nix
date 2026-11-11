self:

{ lib, ... }:

let
  # Each entry of a directory, linked individually so targets can coexist with
  # files the agents create themselves.
  entries = dir: lib.mapAttrs (name: _: dir + "/${name}") (builtins.readDir dir);
  prompts = entries ./prompts;
in
{
  imports = [ self.nixosModules.home ];

  # Shared by Pi and Claude Code. Pi reads its agent-directory AGENTS.md as a
  # context file; Claude Code reads ~/.claude/CLAUDE.md the same way.
  ozozka.home.profiles.agents.files = {
    ".pi/agent" = {
      "AGENTS.md" = ./AGENTS.md;
      inherit prompts;
    };
    ".claude" = {
      "CLAUDE.md" = ./AGENTS.md;
      commands = prompts;
    };
  };
}
