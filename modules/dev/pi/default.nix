{ config, pkgs, ... }:

let
  cfg = config.ozozka;
  settingsFormat = pkgs.formats.json { };
in
{
  imports = [
    ../../home.nix
    ../../options.nix
  ];

  environment.systemPackages = with pkgs; [ pi-coding-agent ];

  ozozka.home.profiles.pi.files = {
    ".pi/agent" = {
      "prompts" = ./prompts;
      # "skills" = ./skills;
      "extensions" = ./extensions;
      "settings.json" = settingsFormat.generate "settings.json" {
        lastChangelogVersion = "1.2.0";

        defaultProvider = "openai-codex";
        defaultModel = "gpt-6.1-sol";
        defaultThinkingLevel = "medium";
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
          # "codemode"
          # "tool_search"
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

      "keybindings.json" = settingsFormat.generate "settings.json" {
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

          toolPendingBg = "bg";
          toolSuccessBg = "overlay";
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

          thinkingOff = "muted";
          thinkingMinimal = "muted";
          thinkingLow = "muted";
          thinkingMedium = "muted";
          thinkingHigh = "muted";
          thinkingXhigh = "muted";
          thinkingMax = "muted";

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
