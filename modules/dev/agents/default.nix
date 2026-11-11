self:

_:

{
  imports = [ self.nixosModules.home ];

  # Shared by Pi and Claude Code. Pi reads its agent-directory AGENTS.md as a
  # context file; Claude Code reads ~/.claude/CLAUDE.md the same way.
  ozozka.home.profiles.agents.files = {
    ".pi/agent"."AGENTS.md" = ./AGENTS.md;
    ".claude"."CLAUDE.md" = ./AGENTS.md;
  };
}
