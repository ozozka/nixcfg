self:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.ozozka;
  agents = cfg.mod.dev.agents;
  settingsFormat = pkgs.formats.json { };
  # Keep code and Markdown in one store path, so adjacent reads and imports resolve
  # whether Pi follows the home-file links or not.
  extensions = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.fileFilter (file: file.hasExt "ts" || file.hasExt "md") ./.;
  };
  prompts = lib.mapAttrs (name: _: ./prompts + "/${name}") (builtins.readDir ./prompts);
in
{
  imports = with self.nixosModules; [
    home
    options
  ];

  environment.systemPackages = with pkgs; [ pi-coding-agent ];

  ozozka.home.profiles.pi.files = {
    ".pi/agent" = {
      # Shared agent assets: a global context file, prompt templates, and skills.
      "AGENTS.md" = agents.instructions;
      inherit (agents) skills;
      "prompts" =
        assert lib.assertMsg (
          lib.intersectAttrs agents.prompts prompts == { }
        ) "Pi-specific prompt names must not conflict with shared prompts.";
        agents.prompts // prompts;
      # Mode definitions for mode.ts.
      "modes" = ./modes;
      # Subagent definitions for subagent.ts.
      "agents" = ./agents;

      "extensions" =
        lib.genAttrs [
          "docs.ts"
          "mode.ts"
          "notify.ts"
          "question.ts"
          "status.ts"
          "subagent.ts"
          "question.md"
          "roadmap.md"
          "subagent.md"
        ] (file: "${extensions}/${file}")
        // {
          # Shared code; Pi skips folders without an index file.
          "lib" = "${extensions}/lib";
          "prompts" = "${extensions}/prompts";
        };

      "settings.json" = settingsFormat.generate "settings.json" {
        lastChangelogVersion = "1.5.0";

        defaultProvider = "openai-codex";
        defaultModel = "gpt-6.1-sol";
        defaultThinkingLevel = "medium";
        enabledModels = [
          "openai-codex/gpt-6.1-sol"
          "minimax/MiniMax-M3.1-Flash"
        ];
        modelThinkingLevels = {
          "minimax/MiniMax-M3.1-Flash" = "medium";
        };
        hideThinkingBlock = true;
        showCacheMissNotices = true;
        # cacheWarming = "streaming"; # "off", "idle"

        defaultTools = [
          "read"
          "bash"
          "edit"
          "write"
          "grep"
          "find"
          "ls"
          "codemode"
        ];

        theme = "ozozka";
        quietStartup = true;
        tuiMode = "regular";
        editorPaddingX = 0;
        outputPad = 0;
        autocompleteMaxVisible = 6;
        showHardwareCursor = true;
        terminal = {
          showImages = false;
          # clearOnShrink = true;
          # showTerminalProgress = true;
          hyperlinks = false;
          images = false;
          trueColor = false;
          # codeBlockIndent = " ";
          # mermaid = "streaming"; # "final"
        };

        retry = {
          enabled = true;
          maxRetries = 6;
          baseDelayMs = 12000;
        };
      };

      "keybindings.json" = settingsFormat.generate "keybindings.json" {
        "app.session.resume" = "ctrl+r";
        "app.thinking.cycle" = "ctrl+t";
      };

      "themes/ozozka.json" = settingsFormat.generate "ozozka.json" {
        name = "ozozka";
        appearance = if cfg.col.isDark then "dark" else "light";
        vars = {
          primary = cfg.col.p.ansi;
          secondary = cfg.col.s.ansi;
          text = cfg.col.f.ansi;
          muted = cfg.col.m.ansi;
          overlay = cfg.col.o.ansi;
          bg = cfg.col.b.ansi;
        };
        colors = {
          accent = "primary";
          border = "muted";
          borderAccent = "primary";
          borderMuted = "overlay";
          success = "primary";
          error = "secondary";
          warning = "secondary";
          muted = "muted";
          dim = "muted";
          text = "text";
          thinkingText = "muted";
          selectedBg = "overlay";

          scrollbarTrack = "overlay";
          scrollbarThumb = "muted";

          searchMatchBg = "overlay";
          searchMatchText = "muted";

          userMessageBg = "overlay";
          userMessageText = "text";

          customMessageBg = "overlay";
          customMessageText = "muted";
          customMessageLabel = "secondary";

          toolPendingBg = "overlay";
          toolSuccessBg = "bg";
          toolErrorBg = "overlay";
          toolTitle = "primary";
          toolOutput = "text";

          mdHeading = "secondary";
          mdLink = "primary";
          mdLinkUrl = "primary";
          mdCode = "primary";
          mdCodeBlock = "primary";
          mdCodeBlockBorder = "muted";
          mdQuote = "secondary";
          mdQuoteBorder = "primary";
          mdHr = "secondary";
          mdListBullet = "muted";

          toolDiffAdded = "primary";
          toolDiffRemoved = "secondary";
          toolDiffContext = "muted";

          syntaxComment = "muted";
          syntaxKeyword = "text";
          syntaxFunction = "secondary";
          syntaxVariable = "text";
          syntaxString = "primary";
          syntaxNumber = "primary";
          syntaxType = "text";
          syntaxOperator = "text";
          syntaxPunctuation = "text";

          thinkingOff = "overlay";
          thinkingMinimal = "overlay";
          thinkingLow = "overlay";
          thinkingMedium = "overlay";
          thinkingHigh = "overlay";
          thinkingXhigh = "overlay";
          thinkingMax = "overlay";

          bashMode = "primary";
        };
        export = {
          pageBg = "bg";
          cardBg = "overlay";
          infoBg = "overlay";
        };
      };
    };
  };
}
