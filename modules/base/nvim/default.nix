{ pkgs, ... }:

{
  imports = [ ../../overlays.nix ];

  # environment.sessionVariables = {
  #   EDITOR = "nvim";
  #   VISUAL = "nvim";
  #   MANPAGER = "nvim +Man!";
  # };

  programs.neovim = {
    enable = true;
    defaultEditor = false;
    viAlias = true;
    withNodeJs = false;
    withPython3 = false;
    withRuby = false;
    runtime = {
      "init.lua".source = ./init.lua;
      "lua".source = ./lua;
      "lsp".source = ./lsp;
      "colors".source = ./colors;
      "spell".source = ./spell;
      "parser".source = "${pkgs.ozozka.treesitter-runtime}/parser";
      "queries".source = "${pkgs.ozozka.treesitter-runtime}/queries";
    };
  };
}
