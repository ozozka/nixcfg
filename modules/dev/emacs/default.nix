{ config, pkgs, ... }:

let
  cfg = config.ozozka;
in
{
  imports = [
    ../../home.nix
    ../../options.nix
  ];

  environment = {
    sessionVariables = {
      VISUAL = "emacseditor";
    };
    systemPackages = with pkgs; [
      mupdf
      hunspellDicts.en_US
      hunspellDicts.tr_TR
      hunspell
    ];
  };

  services.emacs = {
    enable = true;
    defaultEditor = true;
    startWithGraphical = true;
    package = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).emacsWithPackages (epkgs: [
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
    ]);
  };

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
        (defcustom my-theme-col-m "#${cfg.col.m.hex}" "Muted color." :type 'color :group 'my-options)
        (defcustom my-theme-col-o "#${cfg.col.o.hex}" "Overlay color." :type 'color :group 'my-options)
        (defcustom my-theme-col-b "#${cfg.col.b.hex}" "Background color." :type 'color :group 'my-options)

        (defcustom my-theme-fonts-mono "${cfg.font.mono.name}" "Monospace font family." :type 'string :group 'my-options)
        (defcustom my-theme-fonts-serif "${cfg.font.serif.name}" "Serif font family." :type 'string :group 'my-options)
        (defcustom my-theme-fonts-sans "${cfg.font.sans.name}" "Sans-serif font family." :type 'string :group 'my-options)
        (defcustom my-theme-fonts-emoji "${cfg.font.emoji.name}" "Emoji font family." :type 'string :group 'my-options)

        (defcustom my-theme-font-size-t ${toString (cfg.fontSize.t * 10)} "Tiny font size." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-s ${toString (cfg.fontSize.s * 10)} "Small font size." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-m ${toString (cfg.fontSize.m * 10)} "Medium font size." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-l ${toString (cfg.fontSize.l * 10)} "Large font size." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-x ${toString (cfg.fontSize.x * 10)} "Extra font size." :type 'integer :group 'my-options)
        (defcustom my-theme-font-size-h ${toString (cfg.fontSize.h * 10)} "Huge font size." :type 'integer :group 'my-options)

        (provide 'my-options)
        ;;; my-options.el ends here
      '';
      "tree-sitter/queries" = pkgs.ozozka.emacs-ts;
    };
  };
}
