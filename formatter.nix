_: pkgs:

let
  inherit (pkgs) lib;
  lineWidth = 96;

  ruffConfig = (pkgs.formats.toml { }).generate "ruff.toml" {
    line-length = lineWidth;
    target-version = "py${pkgs.python3.sourceVersion.major}${pkgs.python3.sourceVersion.minor}";
    lint.extend-select = [
      "I"
      "UP"
      "B"
      "SIM"
      "C4"
      "RET"
      "PIE"
      "PERF"
      "FURB"
      "RUF"
      "PTH"
    ];
  };
in
pkgs.treefmt.withConfig {
  settings = {
    tree-root-file = "flake.nix";
    on-unmatched = "debug";

    formatter = {
      qmlformat = {
        command = "${pkgs.qt6.qtdeclarative}/bin/qmlformat";
        includes = [ "*.qml" ];
        options = [
          "--inplace"
          "--indent-width"
          "2"
          "--column-width"
          "${toString lineWidth}"
        ];
      };

      luafmt = {
        command = lib.getExe pkgs.emmylua-formatter;
        includes = [ "*.lua" ];
        options = [
          "--config"
          "${(pkgs.formats.toml { }).generate "luafmt.toml" {
            syntax.level = "LuaJIT";
            indent = {
              kind = "Space";
              width = 2;
            };
            layout = {
              max_line_width = lineWidth;
              max_blank_lines = 1;
              prefer_table_layout_from_source = true;
              prefer_call_args_layout_from_source = true;
            };
            output = {
              quote_style = "Double";
              trailing_comma = "Multiline";
              single_arg_call_parens = "Preserve";
            };
            spacing.space_before_func_paren = true;
          }}"
          "--write"
          "--verify"
        ];
      };

      emmylua-check = {
        command = pkgs.writeShellScript "emmylua-check" ''
          status=0
          ${lib.concatLines (
            lib.mapAttrsToList
              (
                dir:
                {
                  env ? { },
                  config ? { },
                }:
                ''
                  ${
                    lib.concatMapAttrsStringSep " " (name: value: "${name}=${lib.escapeShellArg value}") env
                  } ${lib.getExe pkgs.emmylua-check} ${dir} \
                    -c ${dir}/.emmyrc.lua \
                    -c ${pkgs.writeText "emmyrc.json" (builtins.toJSON config)} || status=1
                ''
              )
              # Each workspace gets what its .emmyrc.lua expects from a running system:
              # environment variables, and config merged on top for paths that only exist there.
              {
                "modules/base/nvim".env.VIMRUNTIME = "${pkgs.neovim-unwrapped}/share/nvim/runtime";
                "modules/desktop/hyprland".config.workspace.library = [
                  "${pkgs.hyprland}/share/hypr/stubs"
                  (pkgs.writeTextDir "options.lua" ''
                    return { monitor = 1, keyboard = { layout = "", options = "" } }
                  '')
                ];
              }
          )}
          exit $status
        '';
        includes = [ "*.lua" ];
        priority = 1;
      };

      ruff-check = {
        command = lib.getExe pkgs.ruff;
        includes = [ "*.py" ];
        options = [
          "check"
          "--no-cache"
          "--config"
          "${ruffConfig}"
          "--fix"
        ];
        priority = -1;
      };

      ruff-format = {
        command = lib.getExe pkgs.ruff;
        includes = [ "*.py" ];
        options = [
          "format"
          "--no-cache"
          "--config"
          "${ruffConfig}"
        ];
      };

      biome = {
        command = lib.getExe pkgs.biome;
        includes = [ "*.{md,yaml,yml,json,jsonc,html,css,js,jsx,mjs,cjs,ts,tsx,mts,cts}" ];
        # Biome treats Markdown frontmatter as prose and merges its lines.
        excludes = [
          "modules/dev/agents/prompts/**"
          "modules/dev/agents/skills/**"
          "modules/dev/claude/workflow.md"
          "modules/dev/pi/agents/**"
          "modules/dev/pi/modes/**"
          "modules/dev/pi/prompts/**"
          "modules/dev/pi/question.md"
          "modules/dev/pi/roadmap.md"
          "modules/dev/pi/subagent.md"
        ];
        options = [
          "check"
          "--write"
          "--error-on-warnings"
          # Biome scans the config's directory, so it gets one of its own instead of /nix/store.
          "--config-path=${
            pkgs.writeTextDir "biome.json" (
              builtins.toJSON {
                formatter = {
                  indentStyle = "space";
                  inherit lineWidth;
                };
                html.formatter.enabled = true;
                markdown.formatter.proseWrap = "always";
                linter.rules = {
                  a11y = "error";
                  performance = "error";
                  security = "error";
                  suspicious = "error";
                };
              }
            )
          }"
        ];
      };

      nixf-diagnose = {
        command = lib.getExe pkgs.nixf-diagnose;
        includes = [ "*.nix" ];
        options = [ "--auto-fix" ];
        priority = -2;
      };

      statix = {
        command = lib.getExe pkgs.statix;
        includes = [ "*.nix" ];
        options = [ "fix" ];
        no-positional-arg-support = true;
        priority = -1;
      };

      statix-check = {
        command = lib.getExe pkgs.statix;
        includes = [ "*.nix" ];
        options = [ "check" ];
        no-positional-arg-support = true;
        priority = 1;
      };

      nixfmt = {
        command = lib.getExe pkgs.nixfmt;
        includes = [ "*.nix" ];
        options = [
          "--strict"
          "--width=${toString lineWidth}"
        ];
      };
    };
  };
}
