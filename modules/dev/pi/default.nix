{ pkgs, ... }:

let
  # theme = config.ozozka.theme;
  settingsFormat = pkgs.formats.json { };
in
{
  imports = [
    ../../home.nix
    ../../theme.nix
  ];

  environment.systemPackages = with pkgs; [ pi-coding-agent ];

  ozozka.home.profiles.pi.files = {
    ".pi/agent" = {
      "extensions" = ./extensions;

      "settings.json" = settingsFormat.generate "settings.json" {
        lastChangelogVersion = "1.1.0";

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
        outputPad = 1;
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

      "themes/ozozka.json" = settingsFormat.generate "ozozka.json" {
        name = "ozozka";
        appearance = "dark";
        vars = {
          primary = 6;
          secondary = 1;
          text = 15;
          muted = 7;
          overlay = 8;
          bg = 0;
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
