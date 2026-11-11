self:

{ lib, ... }:

let
  # Each entry of a directory, linked individually so targets can coexist with
  # files the agents create themselves.
  entries = dir: lib.mapAttrs (name: _: dir + "/${name}") (builtins.readDir dir);
  prompts = entries ./prompts;
  skills = entries ./skills;
in
{
  imports = [ self.nixosModules.home ];

  # Shared by Pi and Claude Code. Pi reads its agent-directory AGENTS.md as a
  # context file; Claude Code reads ~/.claude/CLAUDE.md the same way.
  # Pi reads skills from the Agent Skills location ~/.agents/skills. In
  # ~/.claude/skills each skill is linked on its own, beside claude.ai's synced/.
  ozozka.home.profiles.agents.files = {
    ".agents".skills = skills;
    ".pi/agent" = {
      "AGENTS.md" = ./AGENTS.md;
      inherit prompts;
    };
    ".claude" = {
      "CLAUDE.md" = ./AGENTS.md;
      commands = prompts;
      inherit skills;
    };
  };
}
