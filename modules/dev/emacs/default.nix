{ config, pkgs, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [
    ../../home.nix
    ../../options.nix
  ];

  environment.systemPackages = with pkgs; [
    mupdf
    hunspellDicts.en_US
    hunspellDicts.tr_TR
    hunspell
    ((pkgs.emacsPackagesFor pkgs.emacs-pgtk).emacsWithPackages (epkgs: [
      (epkgs.treesit-grammars.with-grammars (
        grammars: with grammars; [
          tree-sitter-bash
          tree-sitter-c
          tree-sitter-cpp
          tree-sitter-css
          tree-sitter-dockerfile
          tree-sitter-gitattributes
          # tree-sitter-git-config
          # tree-sitter-git-rebase
          tree-sitter-gitattributes
          # tree-sitter-gitcommit
          tree-sitter-gitignore
          tree-sitter-html
          tree-sitter-javascript
          tree-sitter-jsdoc
          tree-sitter-json
          tree-sitter-just
          tree-sitter-lua
          tree-sitter-markdown
          tree-sitter-markdown-inline
          tree-sitter-nix
          tree-sitter-python
          tree-sitter-rust
          tree-sitter-tsx
          tree-sitter-typescript
          tree-sitter-typst
          tree-sitter-yaml
        ]
      ))
    ]))
  ];

  ozozka.home.profiles.emacs.files = {
    ".config/emacs" = {
      "early-init.el" = ./early-init.el;
      "init.el" = ./init.el;
      "my-core.el" = ./my-core.el;
      "my-env.el" = ./my-env.el;
      "my-modes.el" = ./my-modes.el;
      "my-net.el" = ./my-net.el;
      "my-theme.el" = ./my-theme.el;
      "my-options.el" = pkgs.writeText "my-options.el" ''
        ;;; my-options.el --- Nix generated options -*- lexical-binding: t; -*-

        ;;; Commentary:
        ;;; Code:

        (defgroup my-options nil "Options for my theme." :group 'convenience)

        (defcustom my-user-fullname "${cfg.user.fullname}" "User full name." :type 'string :group 'my-options)
        (defcustom my-user-email "${cfg.user.email}" "User email." :type 'string :group 'my-options)

        (defcustom my-theme-col-p "#${cfg.col.p.hex}" "Primary color." :type 'color :group 'my-options)
        (defcustom my-theme-col-s "#${cfg.col.s.hex}" "Secondary color." :type 'color :group 'my-options)
        (defcustom my-theme-col-f "#${cfg.col.f.hex}" "Foreground color." :type 'color :group 'my-options)
        (defcustom my-theme-col-m "#${cfg.col.m.hex}" "Muted foreground color." :type 'color :group 'my-options)
        (defcustom my-theme-col-o "#${cfg.col.o.hex}" "Overlay/background accent color." :type 'color :group 'my-options)
        (defcustom my-theme-col-b "#${cfg.col.b.hex}" "Background color." :type 'color :group 'my-options)

        (defcustom my-theme-fonts-mono "${cfg.font.mono.name}" "Monospace font family." :type 'string :group 'my-options)
        (defcustom my-theme-fonts-serif "${cfg.font.serif.name}" "Serif font family." :type 'string :group 'my-options)
        (defcustom my-theme-fonts-sans "${cfg.font.sans.name}" "Sans-serif font family." :type 'string :group 'my-options)
        (defcustom my-theme-fonts-emoji "${cfg.font.emoji.name}" "Emoji font family." :type 'string :group 'my-options)

        (defcustom my-theme-font-size-t ${toString (cfg.fontSize.t * 10)} "Tiny font height." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-s ${toString (cfg.fontSize.s * 10)} "Small font height." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-m ${toString (cfg.fontSize.m * 10)} "Medium font height." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-l ${toString (cfg.fontSize.l * 10)} "Large font height." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-x ${toString (cfg.fontSize.x * 10)} "Extra font height." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-h ${toString (cfg.fontSize.h * 10)} "Huge font height." :type 'integer :group 'my-options)

        (provide 'my-options)
        ;;; my-options.el ends here
      '';
      "tree-sitter/queries" =
        pkgs.runCommand "emacs-treesit-queries" { nativeBuildInputs = [ pkgs.perl ]; }
          ''
            mkdir -p "$out"/{nix,just,typst}
            cp "${pkgs.tree-sitter-grammars.tree-sitter-nix.src}/queries/highlights.scm" "$out/nix/"
            cp "${pkgs.tree-sitter-grammars.tree-sitter-just.src}/queries/just/highlights.scm" "$out/just/"
            cp "${pkgs.tree-sitter-grammars.tree-sitter-typst.src}/queries/typst/highlights.scm" "$out/typst/"
            chmod -R u+w "$out"

            for query in "$out"/*/highlights.scm; do
              perl -0pi -e '
                s{
                  \(\#any-of\?\s+(\@[A-Za-z0-9._-]+)
                  ([^)]*)\)
                }{
                  my ($capture, $values) = ($1, $2);
                  my @values = ($values =~ /"([^"]*)"/g);
                  "(#match? $capture \"^(" . join("|", @values) . ")\$\")"
                }gex;
                s{
                  \(\#match\?\s+(\@[A-Za-z0-9._-]+)\s+"([^"]*)"\)
                }{
                  my ($capture, $regexp) = ($1, $2);
                  $regexp =~ s/\(/\\\\(?:/g;
                  $regexp =~ s/\)/\\\\)/g;
                  $regexp =~ s/\|/\\\\|/g;
                  "(#match? $capture \"$regexp\")"
                }gex;
                s/^\s*\(\#(?:is-not\?|not-eq\?)[^)]*\)\)\s*$/)/mg;
                s/^\s*\(\#offset![^\n]*\)\s*$//mg;
                s/\@attribute\.builtin/\@font-lock-builtin-face/g;
                s/\@constant\.builtin(?:\.[A-Za-z0-9_]+)*/\@font-lock-constant-face/g;
                s/\@constant\.numeric/\@font-lock-number-face/g;
                s/\@constant\.character\.escape/\@font-lock-escape-face/g;
                s/\@constant\.character/\@font-lock-constant-face/g;
                s/\@function\.builtin/\@font-lock-function-face/g;
                s/\@function\.call/\@font-lock-function-call-face/g;
                s/\@function\.method/\@font-lock-function-name-face/g;
                s/\@keyword\.operator/\@font-lock-operator-face/g;
                s/\@keyword\.[A-Za-z0-9_.]+/\@font-lock-keyword-face/g;
                s/\@number\.float/\@font-lock-number-face/g;
                s/\@string\.documentation/\@font-lock-doc-face/g;
                s/\@string\.escape/\@font-lock-escape-face/g;
                s/\@string\.special\.[A-Za-z0-9_.]+/\@font-lock-string-face/g;
                s/\@type\.builtin/\@font-lock-builtin-face/g;
                s/\@variable\.member/\@font-lock-property-name-face/g;
                s/\@variable\.builtin/\@font-lock-builtin-face/g;
                s/\@variable\.parameter\.builtin/\@font-lock-builtin-face/g;
                s/\@variable\.parameter/\@font-lock-variable-name-face/g;
                s/\@markup(?:\.[A-Za-z0-9_]+)+/\@font-lock-doc-face/g;
                s/\@label/\@font-lock-constant-face/g;
                s/\@punctuation(?!\.)/\@font-lock-delimiter-face/g;
                s/ \@(?:embedded|none|spell)//g;
                s{\(select_expression\s+attrpath: \(attrpath \(identifier\)\) \@property\)\s*}{}g;
                s{\(binding\s+attrpath: \(attrpath \(identifier\)\) \@property\)\s*}{}g;
                s/^\(identifier\) \@(?:property|variable)\s*$//mg;
                my @priority;
                s{(\(\(identifier\) \@font-lock-builtin-face\s+\(\#match\?[^\n]+\)\s*\))}{
                  push @priority, $1;
                  ""
                }ge;
                s{\(variable_expression \(identifier\) \@variable\)}{}g;
                $_ .= "\n" . join("\n\n", @priority) . "\n" if @priority;
              ' "$query"
            done

            printf '%s\n' \
              '(binding' \
              '  attrpath: (attrpath attr: (identifier) @font-lock-function-name-face)' \
              '  expression: (function_expression))' \
              >> "$out/nix/highlights.scm"
          '';
    };
  };
}
